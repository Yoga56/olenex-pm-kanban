CLASS lhc_order DEFINITION INHERITING FROM cl_abap_behavior_handler.
  PRIVATE SECTION.
    METHODS get_instance_authorizations FOR INSTANCE AUTHORIZATION
      IMPORTING keys REQUEST requested_authorizations FOR order RESULT result.

    METHODS lock FOR LOCK
      IMPORTING keys FOR LOCK order.

    METHODS read FOR READ
      IMPORTING keys FOR READ order RESULT result.

    METHODS reschedule FOR MODIFY
      IMPORTING keys FOR ACTION order~reschedule.

    METHODS change_status FOR MODIFY
      IMPORTING keys FOR ACTION order~changestatus.
ENDCLASS.

CLASS lhc_order IMPLEMENTATION.

  METHOD get_instance_authorizations.
    " Real authorization is enforced by the access control of ZR_PM_KANBANORDER
    " (read) and by I_MaintenanceOrderTP (change).
    result = VALUE #( FOR key IN keys
                      ( %tky = key-%tky
                        %action-reschedule = if_abap_behv=>auth-allowed
                        %action-changestatus = if_abap_behv=>auth-allowed ) ).
  ENDMETHOD.

  METHOD lock.
    " The enqueue lock is taken by I_MaintenanceOrderTP when it is modified.
  ENDMETHOD.

  METHOD read.
    CHECK keys IS NOT INITIAL.
    SELECT * FROM zr_pm_kanbanorder
      FOR ALL ENTRIES IN @keys
      WHERE maintenanceorder = @keys-maintenanceorder
      INTO TABLE @DATA(orders).
    result = CORRESPONDING #( orders ).
  ENDMETHOD.

  METHOD reschedule.
    SELECT maintenanceorder, maintordbasicstartdate, maintordbasicenddate
      FROM zr_pm_kanbanorder
      FOR ALL ENTRIES IN @keys
      WHERE maintenanceorder = @keys-maintenanceorder
      INTO TABLE @DATA(current).

    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).

      DATA(new_start) = <key>-%param-newstartdate.
      IF new_start IS INITIAL.
        APPEND VALUE #( %tky = <key>-%tky ) TO failed-order.
        APPEND VALUE #( %tky = <key>-%tky
                        %msg = new_message_with_text(
                                 severity = if_abap_behv_message=>severity-error
                                 text     = 'Please provide a new plan start date.' ) )
               TO reported-order.
        CONTINUE.
      ENDIF.

      IF <key>-%param-newenddate IS NOT INITIAL AND <key>-%param-newenddate < new_start.
        APPEND VALUE #( %tky = <key>-%tky ) TO failed-order.
        APPEND VALUE #( %tky = <key>-%tky
                        %msg = new_message_with_text(
                                 severity = if_abap_behv_message=>severity-error
                                 text     = 'The plan end date must not be before the plan start date.' ) )
               TO reported-order.
        CONTINUE.
      ENDIF.

      READ TABLE current ASSIGNING FIELD-SYMBOL(<cur>)
           WITH KEY maintenanceorder = <key>-maintenanceorder.
      IF sy-subrc <> 0.
        APPEND VALUE #( %tky = <key>-%tky %fail-cause = if_abap_behv=>cause-not_found )
               TO failed-order.
        CONTINUE.
      ENDIF.

      " keep the planned duration: shift the basic end date by the same number of days
      READ ENTITY i_maintenanceordertp
  FIELDS ( maintordbasicstartdatetime maintordbasicenddatetime )
  WITH VALUE #( ( maintenanceorder = <key>-maintenanceorder ) )
  RESULT DATA(orders_tp).
      IF orders_tp IS INITIAL.
        APPEND VALUE #( %tky = <key>-%tky %fail-cause = if_abap_behv=>cause-not_found ) TO failed-order.
        CONTINUE.
      ENDIF.

      DATA(start_ts) = orders_tp[ 1 ]-maintordbasicstartdatetime.
      DATA(end_ts)   = orders_tp[ 1 ]-maintordbasicenddatetime.
      IF <cur>-maintordbasicstartdate IS INITIAL OR start_ts IS INITIAL.
        CONVERT DATE new_start TIME '120000' INTO TIME STAMP start_ts TIME ZONE 'UTC'.
        end_ts = start_ts.
      ELSE.
        DATA(seconds) = CONV i( ( new_start - <cur>-maintordbasicstartdate ) * 86400 ).
        start_ts = cl_abap_tstmp=>add( tstmp = start_ts secs = seconds ).
        IF end_ts IS INITIAL.
          end_ts = start_ts.
        ELSE.
          end_ts = cl_abap_tstmp=>add( tstmp = end_ts secs = seconds ).
        ENDIF.
      ENDIF.

      " an explicit end date overrides the shifted one (same 12:00 UTC convention as above)
      IF <key>-%param-newenddate IS NOT INITIAL.
        CONVERT DATE <key>-%param-newenddate TIME '120000' INTO TIME STAMP end_ts TIME ZONE 'UTC'.
      ENDIF.

      MODIFY ENTITY i_maintenanceordertp
        UPDATE FIELDS ( maintordbasicstartdatetime maintordbasicenddatetime )
        WITH VALUE #( ( maintenanceorder           = <key>-maintenanceorder
                        maintordbasicstartdatetime = start_ts
                        maintordbasicenddatetime   = end_ts ) )
        FAILED   DATA(failed_tp)
        REPORTED DATA(reported_tp).


      IF failed_tp IS NOT INITIAL.
        APPEND VALUE #( %tky = <key>-%tky ) TO failed-order.
        APPEND VALUE #( %tky = <key>-%tky
                        %msg = new_message_with_text(
                                 severity = if_abap_behv_message=>severity-error
                                 text     = |Order { <key>-maintenanceorder ALPHA = OUT } cannot be rescheduled (locked, wrong status or no authorization).| ) )
               TO reported-order.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD change_status.
    " Status actions of the released BO I_MaintenanceOrderTP, one step per call.
    " The app chains several calls when a card is dragged over more than one column.
    DATA failed_tp   TYPE RESPONSE FOR FAILED EARLY i_maintenanceordertp.
    DATA reported_tp TYPE RESPONSE FOR REPORTED EARLY i_maintenanceordertp.

    SELECT maintenanceorder, kanbanstatus
      FROM zr_pm_kanbanorder
      FOR ALL ENTRIES IN @keys
      WHERE maintenanceorder = @keys-maintenanceorder
      INTO TABLE @DATA(current).

    LOOP AT keys ASSIGNING FIELD-SYMBOL(<key>).
      READ TABLE current ASSIGNING FIELD-SYMBOL(<cur>)
           WITH KEY maintenanceorder = <key>-maintenanceorder.
      IF sy-subrc <> 0.
        APPEND VALUE #( %tky = <key>-%tky %fail-cause = if_abap_behv=>cause-not_found ) TO failed-order.
        CONTINUE.
      ENDIF.

      CLEAR: failed_tp, reported_tp.
      DATA(step) = |{ <cur>-kanbanstatus }>{ <key>-%param-targetstatus }|.
      DATA(supported) = abap_true.

      CASE step.
        WHEN '10>20'.   " Created -> Released
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE releasemaintenanceorder FROM VALUE #( ( maintenanceorder = <key>-maintenanceorder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '20>30'.   " Released -> Main work completed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE setmaintordtomainworkcomplete FROM VALUE #( ( maintenanceorder = <key>-maintenanceorder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '30>40'.   " Main work completed -> Technically completed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE setmaintordtotechcompleted FROM VALUE #( ( maintenanceorder = <key>-maintenanceorder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '40>50'.   " Technically completed -> Closed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE setmaintorderstatustoclosed FROM VALUE #( ( maintenanceorder = <key>-maintenanceorder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '50>40'.   " back: reset Closed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE resetmaintorderstatusclosed FROM VALUE #( ( maintenanceorder = <key>-maintenanceorder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '40>30'.   " back: reset Technically completed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE resetmaintordststechcompleted FROM VALUE #( ( maintenanceorder = <key>-maintenanceorder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN '30>20'.   " back: reset Main work completed
          MODIFY ENTITY i_maintenanceordertp
            EXECUTE resetmaintordstsmainworkcmplt FROM VALUE #( ( maintenanceorder = <key>-maintenanceorder ) )
            FAILED failed_tp REPORTED reported_tp.
        WHEN OTHERS.
          supported = abap_false.
      ENDCASE.

      IF supported = abap_false.
        APPEND VALUE #( %tky = <key>-%tky ) TO failed-order.
        APPEND VALUE #( %tky = <key>-%tky
                        %msg = new_message_with_text(
                                 severity = if_abap_behv_message=>severity-error
                                 text     = |Status change { <cur>-kanbanstatus } to { <key>-%param-targetstatus } is not supported in one step.| ) )
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
