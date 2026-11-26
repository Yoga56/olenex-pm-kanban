@AccessControl.authorizationCheck: #CHECK
@EndUserText.label: 'PM Order Kanban - Projection'
@Metadata.ignorePropagatedAnnotations: true
define root view entity ZC_PM_KANBANORDER
  provider contract transactional_query
  as projection on ZR_PM_KANBANORDER
{
  key MaintenanceOrder,
      MaintenanceOrderDesc,
      MaintenanceOrderType,
      MaintPriority,
      MaintenancePlanningPlant,
      MaintenancePlant,
      MaintenancePlannerGroup,
      MainWorkCenter,
      MainWorkCenterPlant,
      FunctionalLocation,
      FunctionalLocationName,
      Equipment,
      EquipmentName,
      MaintOrdBasicStartDate,
      MaintOrdBasicEndDate,
      ScheduledBasicStartDate,
      OrderCreationDate,
      KanbanStatus,
      MaintenanceProcessingPhase,
      MaintenanceProcessingPhaseText,
      MaintenanceNotification,
      NotificationReportDate,
      NotificationCreatedOn,
      LastChangeDateTime,
      _MaintenanceOrder
}
