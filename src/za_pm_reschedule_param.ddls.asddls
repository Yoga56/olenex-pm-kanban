@EndUserText.label: 'Parameter for action Reschedule'
define abstract entity ZA_PM_RESCHEDULE_PARAM
{
  @EndUserText.label: 'New plan start date'
  NewStartDate : abap.dats;
  @EndUserText.label: 'New plan end date (optional)'
  NewEndDate   : abap.dats;
}
