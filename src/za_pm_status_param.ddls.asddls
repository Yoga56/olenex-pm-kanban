@EndUserText.label: 'Parameter for action ChangeStatus'
define abstract entity ZA_PM_STATUS_PARAM
{
  @EndUserText.label: 'Target status (10, 20, 30, 40, 50)'
  TargetStatus : abap.char( 2 );
}
