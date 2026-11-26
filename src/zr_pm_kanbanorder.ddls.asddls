@AccessControl.authorizationCheck: #CHECK
@EndUserText.label: 'PM Order Kanban - Base View'
@Metadata.ignorePropagatedAnnotations: true
@ObjectModel.usageType: { serviceQuality: #C, sizeCategory: #XL, dataClass: #TRANSACTIONAL }
define root view entity ZR_PM_KANBANORDER
  as select from I_MaintenanceOrderBasic as Ord

    left outer join I_MaintenanceOrderStatus as Sts
      on Sts.MaintenanceOrder = Ord.MaintenanceOrder

    left outer join I_MaintenanceNotification as Ntf
      on  Ntf.MaintenanceNotification = Ord.MaintenanceNotification
      and Ord.MaintenanceNotification <> ''

  association [0..1] to I_EquipmentText       as _EquipmentText
    on  $projection.Equipment = _EquipmentText.Equipment
    and _EquipmentText.Language = $session.system_language
  association [0..1] to I_MaintenanceOrderPhaseText as _PhaseText
    on  $projection.MaintenanceProcessingPhase = _PhaseText.MaintenanceProcessingPhase
    and _PhaseText.Language = $session.system_language
  association [0..1] to I_FunctionalLocation  as _FunctionalLocation
    on  $projection.FunctionalLocation = _FunctionalLocation.FunctionalLocation
{
  key Ord.MaintenanceOrder,

      Ord.MaintenanceOrderDesc,
      Ord.MaintenanceOrderType,
      Ord.MaintPriority,

      // organisation (also needed by the inherited access control)
      Ord.MaintenancePlanningPlant,
      Ord.MaintenancePlant,
      Ord.MaintenancePlannerGroup,
      Ord.ResponsibleCostCenter,
      Ord.MainWorkCenter,
      Ord.MainWorkCenterPlant,

      // technical object
      Ord._LocationAccountAssignment.FunctionalLocation as FunctionalLocation,
      _FunctionalLocation.FunctionalLocationName        as FunctionalLocationName,
      Ord.Equipment,
      _EquipmentText.EquipmentName                      as EquipmentName,

      // dates (DATS, initial value = not set)
      Ord.MaintOrdBasicStartDate,                       // "Plan start date"
      Ord.MaintOrdBasicEndDate,
      Ord.ScheduledBasicStartDate,
      Ord.CreationDate                                  as OrderCreationDate,

      // status -> Kanban column. Highest reached system status wins.
      //   10 Created | 20 Released | 30 Main work completed | 40 Technically completed | 50 Closed
      cast( case
              when Sts.MaintOrderIsBusinessCompleted  = 'X' then '50'
              when Sts.MaintOrdIsTechlyCmpltd         = 'X' then '40'
              when Sts.MaintOrderMainWorkIsCompleted  = 'X' then '30'
              when Sts.MaintenanceOrderIsReleased     = 'X' then '20'
              else '10'
            end as abap.char( 2 ) )                     as KanbanStatus,
      Ord.MaintenanceProcessingPhase,
      _PhaseText.MaintenanceProcessingPhaseDesc         as MaintenanceProcessingPhaseText,

      // notification
      Ord.MaintenanceNotification,
      Ntf.NotificationCreationDate                      as NotificationReportDate,   // QMEL-QMDAT "Notification date"
      Ntf.CreationDate                                  as NotificationCreatedOn,    // QMEL-ERDAT "Created on"

      Ord.LastChangeDateTime
}
