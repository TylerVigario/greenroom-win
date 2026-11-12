# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Write an error AS the command the operator typed, with that command's error semantics.

  Every error that ends one item of a command's work goes through here: a session that did
  not come up, an instance that is refused, a name that matches nothing. The command then
  carries on to the next item, as a cmdlet does -- unless its caller asked it to stop.

  WHY IT IS NEEDED. The module sets $ErrorActionPreference = 'Stop', so that a cmdlet that
  fails inside it throws instead of being stepped over. Every function here inherits that,
  and so does every error a command means only to REPORT: a bare Write-Error is
  terminating, the `continue` after it never runs, and a command looping over instances
  stops at the first one it cannot act on. Measured 2026-11-12, the two obvious patterns
  are both wrong, in opposite directions:

      bare Write-Error                     throws by default, ending the loop
      Write-Error -ErrorAction Continue    carries on, but IGNORES a caller's -ErrorAction Stop

  $Cmdlet.WriteError alone is the first row again: the runtime reads the preference from
  the scope it is called in, which inherits Stop.

  WHAT IT DOES. It decides the action the way a cmdlet would -- the -ErrorAction the caller
  bound, or else the CALLER's $ErrorActionPreference, read through $Cmdlet.SessionState --
  and sets it as a preference local to THIS scope, which is where the runtime reads it when
  WriteError is called. Nothing after the call inherits it, so the module's own code keeps
  Stop. Measured: by default the command carries on; -ErrorAction Stop and a caller's
  preference of Stop both throw at the first error; a call from inside the module, where
  the preference is Stop, throws, which is what lets Update- catch a failed restart; and
  -ErrorVariable captures every one.

  THROUGH THE CALLER'S CMDLET, as Resolve-InstanceName already did, so the error names the
  command that was typed rather than a private function the operator cannot see or call.
#>
function Write-CommandError {
    [CmdletBinding(DefaultParameterSetName = 'Message')]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,

        [Parameter(Mandatory, ParameterSetName = 'Message')][string]$Message,

        # The first half of FullyQualifiedErrorId, which reads '<ErrorId>,<command>'.
        [Parameter(Mandatory, ParameterSetName = 'Message')][string]$ErrorId,

        [Parameter(ParameterSetName = 'Message')]
        [System.Management.Automation.ErrorCategory]$Category = 'NotSpecified',

        [Parameter(ParameterSetName = 'Message')][object]$TargetObject,

        # For a caller that builds its own record: its own exception type and id.
        [Parameter(Mandatory, ParameterSetName = 'Record')]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($PSCmdlet.ParameterSetName -eq 'Message') {
        $exception = switch ($Category) {
            'ObjectNotFound'   { [System.Management.Automation.ItemNotFoundException]::new($Message) }
            'InvalidArgument'  { [System.ArgumentException]::new($Message) }
            'PermissionDenied' { [System.UnauthorizedAccessException]::new($Message) }
            'OperationTimeout' { [System.TimeoutException]::new($Message) }
            default            { [System.InvalidOperationException]::new($Message) }
        }
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new($exception, $ErrorId, $Category, $TargetObject)
    }

    $bound  = $Cmdlet.MyInvocation.BoundParameters
    $action = if ($bound.ContainsKey('ErrorAction')) { $bound['ErrorAction'] }
              else { $Cmdlet.SessionState.PSVariable.GetValue('ErrorActionPreference') }
    if ($null -eq $action) { $action = 'Continue' }

    # Read by the command runtime when WriteError is called and -ErrorAction was not bound.
    # Local to this scope, so it ends with this call.
    $ErrorActionPreference = $action
    $Cmdlet.WriteError($ErrorRecord)
}
