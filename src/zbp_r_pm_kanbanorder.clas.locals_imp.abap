CLASS lhc_order DEFINITION INHERITING FROM cl_abap_behavior_handler.
  PRIVATE SECTION.
    METHODS get_instance_authorizations FOR INSTANCE AUTHORIZATION
      IMPORTING keys REQUEST requested_authorizations FOR Order RESULT result.

    METHODS lock FOR LOCK
      IMPORTING keys FOR LOCK Order.

    METHODS read FOR READ
      IMPORTING keys FOR READ Order RESULT result.

    METHODS reschedule FOR MODIFY
      IMPORTING keys FOR ACTION Order~reschedule.

    METHODS change_status FOR MODIFY
      IMPORTING keys FOR ACTION Order~changeStatus.
ENDCLASS.

CLASS lhc_order IMPLEMENTATION.

  METHOD get_instance_authorizations.
    " Real authorization is enforced by the access control of ZR_PM_KANBANORDER
    " (read) and by I_MaintenanceOrderTP (change).
    result = VALUE #( FOR key IN keys
                      ( %tky = key-%tky
                        %action-reschedule = if_abap_behv=>auth-allowed
                        %action-changeStatus = if_abap_behv=>auth-allowed ) ).
  ENDMETHOD.

  METHOD lock.
    " The enqueue lock is taken by I_MaintenanceOrderTP when it is modified.
  ENDMETHOD.

  METHOD read.
    CHECK keys IS NOT INITIAL.
    SELECT * FROM zr_pm_kanbanorder
      FOR ALL ENTRIES IN @keys
      WHERE MaintenanceOrder = @keys-MaintenanceOrder
      INTO TABLE @DATA(orders).
    result = CORRESPONDING #( orders ).
  ENDMETHOD.

  METHOD reschedule.
    SELECT MaintenanceOrder, MaintOrdBasicStartDate, MaintOrdBasicEndDate
      FROM zr_pm_kanbanorder
      FOR ALL ENTRIES IN @keys
      WHERE MaintenanceOrder = @keys-MaintenanceOrder
      INTO TABLE @DATA(current).

    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).

      DATA(new_start) = <key>-%param-NewStartDate.
      IF new_start IS INITIAL.
        APPEND VALUE #( %tky = <key>-%tky ) TO failed-order.
        APPEND VALUE #( %tky = <key>-%tky
                        %msg = new_message_with_text(
                                 severity = if_abap_behv_message=>severity-error
                                 text     = 'Please provide a new plan start date.' ) )
               TO reported-order.
        CONTINUE.
      ENDIF.

      IF <key>-%param-NewEndDate IS NOT INITIAL AND <key>-%param-NewEndDate < new_start.
        APPEND VALUE #( %tky = <key>-%tky ) TO failed-order.
        APPEND VALUE #( %tky = <key>-%tky
                        %msg = new_message_with_text(
                                 severity = if_abap_behv_message=>severity-error
                                 text     = 'The plan end date must not be before the plan start date.' ) )
               TO reported-order.
        CONTINUE.
      ENDIF.

      READ TABLE current ASSIGNING FIELD-SYMBOL(<cur>)
           WITH KEY MaintenanceOrder = <key>-MaintenanceOrder.
      IF sy-subrc <> 0.
        APPEND VALUE #( %tky = <key>-%tky %fail-cause = if_abap_behv=>cause-not_found )
               TO failed-order.
        CONTINUE.
      ENDIF.

      " the released BO only lets us change the date-time fields: shift both by the same number of days (keeps the duration)
      READ ENTITY i_maintenanceordertp
        FIELDS ( MaintOrdBasicStartDateTime MaintOrdBasicEndDateTime )
        WITH VALUE #( ( MaintenanceOrder = <key>-MaintenanceOrder ) )
        RESULT DATA(orders_tp).
      IF orders_tp IS INITIAL.
        APPEND VALUE #( %tky = <key>-%tky %fail-cause = if_abap_behv=>cause-not_found ) TO failed-order.
        CONTINUE.
      ENDIF.

      DATA(start_ts) = orders_tp[ 1 ]-MaintOrdBasicStartDateTime.
      DATA(end_ts)   = orders_tp[ 1 ]-MaintOrdBasicEndDateTime.
      IF <cur>-MaintOrdBasicStartDate IS INITIAL OR start_ts IS INITIAL.
        CONVERT DATE new_start TIME '120000' INTO TIME STAMP start_ts TIME ZONE 'UTC'.
        end_ts = start_ts.
      ELSE.
        DATA(seconds) = CONV i( ( new_start - <cur>-MaintOrdBasicStartDate ) * 86400 ).
        start_ts = cl_abap_tstmp=>add( tstmp = start_ts secs = seconds ).
        IF end_ts IS INITIAL.
          end_ts = start_ts.
        ELSE.
          end_ts = cl_abap_tstmp=>add( tstmp = end_ts secs = seconds ).
        ENDIF.
      ENDIF.

      " an explicit end date overrides the shifted one (same 12:00 UTC convention as above)
      IF <key>-%param-NewEndDate IS NOT INITIAL.
        CONVERT DATE <key>-%param-NewEndDate TIME '120000' INTO TIME STAMP end_ts TIME ZONE 'UTC'.
      ENDIF.

      MODIFY ENTITY i_maintenanceordertp
        UPDATE FIELDS ( MaintOrdBasicStartDateTime MaintOrdBasicEndDateTime )
        WITH VALUE #( ( MaintenanceOrder           = <key>-MaintenanceOrder
                        MaintOrdBasicStartDateTime = start_ts
                        MaintOrdBasicEndDateTime   = end_ts ) )
        FAILED   DATA(failed_tp)
        REPORTED DATA(reported_tp).

      IF failed_tp IS NOT INITIAL.
        APPEND VALUE #( %tky = <key>-%tky ) TO failed-order.
        APPEND VALUE #( %tky = <key>-%tky
                        %msg = new_message_with_text(
                                 severity = if_abap_behv_message=>severity-error
                                 text     = |Order { <key>-MaintenanceOrder ALPHA = OUT } cannot be rescheduled (locked, wrong status or no authorization).| ) )
               TO reported-order.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD change_status.
    " Status actions of the released BO I_MaintenanceOrderTP, one step per call.
    " The app chains several calls when a card is dragged over more than one column.
    DATA failed_tp   TYPE RESPONSE FOR FAILED EARLY i_maintenanceordertp.
    DATA reported_tp TYPE RESPONSE FOR REPORTED EARLY i_maintenanceordertp.

    SELECT MaintenanceOrder, KanbanStatus
      FROM zr_pm_kanbanorder
      FOR ALL ENTRIES IN @keys
      WHERE MaintenanceOrder = @keys-MaintenanceOrder
      INTO TABLE @DATA(current).

    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      READ TABLE current ASSIGNING FIELD-SYMBOL(<cur>)
           WITH KEY MaintenanceOrder = <key>-MaintenanceOrder.
      IF sy-subrc <> 0.
        APPEND VALUE #( %tky = <key>-%tky %fail-cause = if_abap_behv=>cause-not_found ) TO failed-order.
        CONTINUE.
      ENDIF.

      CLEAR: failed_tp, reported_tp.
      DATA(step) = |{ <cur>-KanbanStatus }>{ <key>-%param-TargetStatus }|.
      DATA(supported) = abap_true.

      CASE step.
        WHEN '10>20'.   " Created -> Released
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE ReleaseMaintenanceOrder FROM VALUE #( ( MaintenanceOrder = <key>-MaintenanceOrder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '20>30'.   " Released -> Main work completed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE SetMaintOrdToMainWorkComplete FROM VALUE #( ( MaintenanceOrder = <key>-MaintenanceOrder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '30>40'.   " Main work completed -> Technically completed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE SetMaintOrdToTechCompleted FROM VALUE #( ( MaintenanceOrder = <key>-MaintenanceOrder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '40>50'.   " Technically completed -> Closed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE SetMaintOrderStatusToClosed FROM VALUE #( ( MaintenanceOrder = <key>-MaintenanceOrder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '50>40'.   " back: reset Closed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE ResetMaintOrderStatusClosed FROM VALUE #( ( MaintenanceOrder = <key>-MaintenanceOrder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '40>30'.   " back: reset Technically completed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE ResetMaintOrdStsTechCompleted FROM VALUE #( ( MaintenanceOrder = <key>-MaintenanceOrder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '30>20'.   " back: reset Main work completed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE ResetMaintOrdStsMainWorkCmplt FROM VALUE #( ( MaintenanceOrder = <key>-MaintenanceOrder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN OTHERS.
          supported = abap_false.
      ENDCASE.

      IF supported = abap_false.
        APPEND VALUE #( %tky = <key>-%tky ) TO failed-order.
        APPEND VALUE #( %tky = <key>-%tky
                        %msg = new_message_with_text(
                                 severity = if_abap_behv_message=>severity-error
                                 text     = |Status change { <cur>-KanbanStatus } to { <key>-%param-TargetStatus } is not supported in one step.| ) )
               TO reported-order.
        CONTINUE.
      ENDIF.

      " pass the messages of the standard business object on to the app
      LOOP AT reported_tp-maintenanceorder ASSIGNING FIELD-SYMBOL(<msg>).
        APPEND VALUE #( %tky = <key>-%tky %msg = <msg>-%msg ) TO reported-order.
      ENDLOOP.
      IF failed_tp IS NOT INITIAL.
        APPEND VALUE #( %tky = <key>-%tky ) TO failed-order.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

ENDCLASS.

* Required for an unmanaged BO. Nothing to save here: I_MaintenanceOrderTP persists its own changes.
CLASS lsc_order DEFINITION INHERITING FROM cl_abap_behavior_saver.
  PROTECTED SECTION.
    METHODS finalize          REDEFINITION.
    METHODS check_before_save REDEFINITION.
    METHODS save              REDEFINITION.
    METHODS cleanup           REDEFINITION.
    METHODS cleanup_finalize  REDEFINITION.
ENDCLASS.

CLASS lsc_order IMPLEMENTATION.
  METHOD finalize.
  ENDMETHOD.
  METHOD check_before_save.
  ENDMETHOD.
  METHOD save.
  ENDMETHOD.
  METHOD cleanup.
  ENDMETHOD.
  METHOD cleanup_finalize.
  ENDMETHOD.
ENDCLASS.
