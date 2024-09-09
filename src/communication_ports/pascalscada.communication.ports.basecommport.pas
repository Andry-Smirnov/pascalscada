unit pascalscada.communication.ports.basecommport;


{$mode objfpc}{$H+}


interface


uses
  Classes,
  SysUtils,
  fgl, syncobjs;


type
  TpSCADANotificationList = specialize TFPGList<TThreadMethod>;

  TpSCADAIOResult = -$7FFFFFFF..0;

  { TpSCADACustomCommPort }

  TpSCADACustomCommPort = class(TComponent)
  private
    FActive, FActiveInLoading: boolean;
    FPortBeingDestroyed: integer;

    FOnPortClose: TNotifyEvent;
    FOnPortCloseError: TNotifyEvent;
    FOnPortDisconnected: TNotifyEvent;
    FOnPortOpen: TNotifyEvent;
    FOnPortOpenError: TNotifyEvent;
    FOnReadError: TNotifyEvent;
    FOnWriteError: TNotifyEvent;

    //handler list.
    FPortOpenHandlerList, FPortOpenErrorHandlerList, FPortCloseHandlerList,
    FPortCloseErrorHandlerList, FPortDisconnectedHandlerList,
    FWriteErrorHandlerList, FReadErrorHandlerList: TpSCADANotificationList;

    //handler list mutexes
    FPortOpenHandlerListCS, FPortOpenErrorHandlerListCS,
    FPortCloseHandlerListCS, FPortCloseErrorHandlerListCS,
    FPortDisconnectedHandlerListCS, FWriteErrorHandlerListCS,
    FReadErrorHandlerListCS, FOperationCS, FLockCS: TCriticalSection;

    FLastOSErrorNumber: longint;
    FLastOSErrorMessage: ansistring;

    procedure SetActive(AValue: boolean);
    procedure InternalOpen;
    procedure InternalClose;

  protected
    FExclusiveDevice: boolean;

    function BeingDestroyed: boolean;
    procedure CallPortCloseHandlers; virtual;
    procedure CallPortCloseErrorHandlers; virtual;
    procedure CallPortDisconnectedHandlers; virtual;
    procedure CallPortOpenHandlers; virtual;
    procedure CallPortOpenErrorHandlers; virtual;
    procedure CallReadErrorHandlers; virtual;
    procedure CallWriteErrorHandlers; virtual;
    function Close: boolean; virtual; abstract;
    procedure DoExceptionIfActive; virtual;
    procedure DoPortClose; virtual;
    procedure DoPortCloseError; virtual;
    procedure DoPortDisconnected; virtual;
    procedure DoPortOpen; virtual;
    procedure DoPortOpenError; virtual;
    procedure DoReadError; virtual;
    procedure DoWriteError; virtual;
    procedure Loaded; override;
    function Open: boolean; virtual; abstract;
    function PortSettingsOK: boolean; virtual;
    procedure RefreshLastOSError;

    property Active: boolean read FActive write SetActive;
    property LastOSErrorNumber: longint read FLastOSErrorNumber;
    property LastOSErrorMessage: ansistring read FLastOSErrorMessage;
    property OnPortClose: TNotifyEvent read FOnPortClose write FOnPortClose;
    property OnPortCloseError: TNotifyEvent read FOnPortCloseError
      write FOnPortCloseError;
    property OnPortDisconnected: TNotifyEvent
      read FOnPortDisconnected write FOnPortDisconnected;
    property OnPortOpen: TNotifyEvent read FOnPortOpen write FOnPortOpen;
    property OnPortOpenError: TNotifyEvent read FOnPortOpenError write FOnPortOpenError;
    property OnReadError: TNotifyEvent read FOnReadError write FOnReadError;
    property OnWriteError: TNotifyEvent read FOnWriteError write FOnWriteError;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure AddPortCloseErrorHandler(handler: TThreadMethod);
    procedure AddPortCloseHandler(handler: TThreadMethod);
    procedure AddPortDisconnectedHandler(handler: TThreadMethod);
    procedure AddPortOpenHandler(handler: TThreadMethod);
    procedure AddPortOpenErrorHandler(handler: TThreadMethod);
    procedure AddReadErrorHandler(handler: TThreadMethod);
    procedure AddWriteErrorHandler(handler: TThreadMethod);

    procedure Begin_IO_Operation;
    procedure End_IO_Operation;
    procedure Lock;
    function Read(buffer: pbyte; buffer_size, max_retries: longint;
      var bytes_read: longint): longint; virtual; abstract; overload;
    function Read(var buffer: TBytes; bytes_to_read, max_retries: longint;
      var bytes_read: longint): longint; virtual;
    function ReallyActive: boolean; virtual;
    procedure RemoveHandler(handler: TThreadMethod);
    procedure RemoveHandlersOfObject(AnObject: TObject);
    procedure Unlock;
    function Write(buffer: pbyte; buffer_size, max_retries: longint;
      var bytes_written: longint): longint; virtual; abstract; overload;
    function Write(buffer: TBytes; max_retries: longint;
      var bytes_written: longint): longint; virtual;
  end;


const
  iorOK = TpSCADAIOResult(0);
  iorTimeOut = TpSCADAIOResult(-1);
  iorNotReady = TpSCADAIOResult(-2);
  iorNone = TpSCADAIOResult(-3);
  iorPortError = TpSCADAIOResult(-4);


resourcestring
  SPascalSCADA_CannotChangeSettingsWhileActive = 'Cannot change settings while active!';


implementation


uses
  Math;

  { TCustomCommPort }

procedure TpSCADACustomCommPort.SetActive(AValue: boolean);
begin
  if ComponentState * [csReading, csLoading] <> [] then
    begin
      FActiveInLoading := AValue;
      exit;
    end;

  //evita a abertura/fechamento da porta em edição, quando um dispositivo
  //e de uso exclusivo (porta serial).

  //avoid the open/close of communication port in design-time if the communication
  //port is exclusive (like a serial port)
  if FExclusiveDevice and (csDesigning in ComponentState) then
    begin
      if AValue then
        begin
          if PortSettingsOK then
            begin
              FActive := True;
            end;
        end
      else
        begin
          FActive := False;
        end;
    end
  else
    begin
      if AValue then
        InternalOpen
      else
        InternalClose;
    end;
end;

procedure TpSCADACustomCommPort.InternalOpen;
begin
  FLockCS.Acquire;
  FOperationCS.Acquire;
  try
    if Open then
      FActive := True;
  finally
    FOperationCS.Release;
    FLockCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.InternalClose;
begin
  FLockCS.Acquire;
  FOperationCS.Acquire;
  try
    if Close then
      FActive := False;
  finally
    FOperationCS.Leave;
    FLockCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.AddPortOpenHandler(handler: TThreadMethod);
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortOpenHandlerListCS.Enter;
  try
    if FPortOpenHandlerList.IndexOf(handler) = -1 then
      FPortOpenHandlerList.Add(handler);
  finally
    FPortOpenHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.AddPortOpenErrorHandler(handler: TThreadMethod);
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortOpenErrorHandlerListCS.Enter;
  try
    if FPortOpenErrorHandlerList.IndexOf(handler) = -1 then
      FPortOpenErrorHandlerList.Add(handler);
  finally
    FPortOpenErrorHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.AddPortCloseHandler(handler: TThreadMethod);
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortCloseHandlerListCS.Enter;
  try
    if FPortCloseHandlerList.IndexOf(handler) = -1 then
      FPortCloseHandlerList.Add(handler);
  finally
    FPortCloseHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.AddPortCloseErrorHandler(handler: TThreadMethod);
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortCloseErrorHandlerListCS.Enter;
  try
    if FPortCloseErrorHandlerList.IndexOf(handler) = -1 then
      FPortCloseErrorHandlerList.Add(handler);
  finally
    FPortCloseErrorHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.AddPortDisconnectedHandler(handler: TThreadMethod);
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortDisconnectedHandlerListCS.Enter;
  try
    if FPortDisconnectedHandlerList.IndexOf(handler) = -1 then
      FPortDisconnectedHandlerList.Add(handler);
  finally
    FPortDisconnectedHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.AddReadErrorHandler(handler: TThreadMethod);
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FReadErrorHandlerListCS.Enter;
  try
    if FReadErrorHandlerList.IndexOf(handler) = -1 then
      FReadErrorHandlerList.Add(handler);
  finally
    FReadErrorHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.AddWriteErrorHandler(handler: TThreadMethod);
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FWriteErrorHandlerListCS.Enter;
  try
    if FWriteErrorHandlerList.IndexOf(handler) = -1 then
      FWriteErrorHandlerList.Add(handler);
  finally
    FWriteErrorHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.RemoveHandler(handler: TThreadMethod);
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortOpenHandlerListCS.Enter;
  try
    FPortOpenHandlerList.Remove(handler);
  finally
    FPortOpenHandlerListCS.Leave;
  end;

  FPortOpenErrorHandlerListCS.Enter;
  try
    FPortOpenErrorHandlerList.Remove(handler);
  finally
    FPortOpenErrorHandlerListCS.Leave;
  end;

  FPortCloseHandlerListCS.Enter;
  try
    FPortCloseHandlerList.Remove(handler);
  finally
    FPortCloseHandlerListCS.Leave;
  end;

  FPortCloseErrorHandlerListCS.Enter;
  try
    FPortCloseErrorHandlerList.Remove(handler);
  finally
    FPortCloseErrorHandlerListCS.Leave;
  end;

  FPortDisconnectedHandlerListCS.Enter;
  try
    FPortDisconnectedHandlerList.Remove(handler);
  finally
    FPortDisconnectedHandlerListCS.Leave;
  end;

  FReadErrorHandlerListCS.Enter;
  try
    FReadErrorHandlerList.Remove(handler);
  finally
    FReadErrorHandlerListCS.Leave;
  end;

  FWriteErrorHandlerListCS.Enter;
  try
    FWriteErrorHandlerList.Remove(handler);
  finally
    FWriteErrorHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.RemoveHandlersOfObject(AnObject: TObject);
var
  i: integer;
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortOpenHandlerListCS.Enter;
  try
    for i := 0 to FPortOpenHandlerList.Count - 1 do
      if TMethod(FPortOpenHandlerList.Items[i]).Data = Pointer(AnObject) then
        FPortOpenHandlerList.Delete(i);
  finally
    FPortOpenHandlerListCS.Leave;
  end;

  FPortOpenErrorHandlerListCS.Enter;
  try
    for i := 0 to FPortOpenErrorHandlerList.Count - 1 do
      if TMethod(FPortOpenErrorHandlerList.Items[i]).Data = Pointer(AnObject) then
        FPortOpenErrorHandlerList.Delete(i);
  finally
    FPortOpenErrorHandlerListCS.Leave;
  end;

  FPortCloseHandlerListCS.Enter;
  try
    for i := 0 to FPortCloseHandlerList.Count - 1 do
      if TMethod(FPortCloseHandlerList.Items[i]).Data = Pointer(AnObject) then
        FPortCloseHandlerList.Delete(i);
  finally
    FPortCloseHandlerListCS.Leave;
  end;

  FPortCloseErrorHandlerListCS.Enter;
  try
    for i := 0 to FPortCloseErrorHandlerList.Count - 1 do
      if TMethod(FPortCloseErrorHandlerList.Items[i]).Data = Pointer(AnObject) then
        FPortCloseErrorHandlerList.Delete(i);
  finally
    FPortCloseErrorHandlerListCS.Leave;
  end;

  FPortDisconnectedHandlerListCS.Enter;
  try
    for i := 0 to FPortDisconnectedHandlerList.Count - 1 do
      if TMethod(FPortDisconnectedHandlerList.Items[i]).Data = Pointer(AnObject) then
        FPortDisconnectedHandlerList.Delete(i)
  finally
    FPortDisconnectedHandlerListCS.Leave;
  end;

  FReadErrorHandlerListCS.Enter;
  try
    for i := 0 to FReadErrorHandlerList.Count - 1 do
      if TMethod(FReadErrorHandlerList.Items[i]).Data = Pointer(AnObject) then
        FReadErrorHandlerList.Delete(i)
  finally
    FReadErrorHandlerListCS.Leave;
  end;

  FWriteErrorHandlerListCS.Enter;
  try
    for i := 0 to FWriteErrorHandlerList.Count - 1 do
      if TMethod(FWriteErrorHandlerList.Items[i]).Data = Pointer(AnObject) then
        FWriteErrorHandlerList.Delete(i)
  finally
    FWriteErrorHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.CallPortOpenHandlers;
var
  i: integer;
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortOpenHandlerListCS.Enter;
  try
    for i := 0 to FPortOpenHandlerList.Count - 1 do
      try
        if Assigned(FPortOpenHandlerList.Items[i]) then
          FPortOpenHandlerList.Items[i]();
      except
      end;
  finally
    FPortOpenHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.CallPortOpenErrorHandlers;
var
  i: integer;
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortOpenErrorHandlerListCS.Enter;
  try
    for i := 0 to FPortOpenErrorHandlerList.Count - 1 do
      try
        if Assigned(FPortOpenErrorHandlerList.Items[i]) then
          FPortOpenErrorHandlerList.Items[i]();
      except
      end;
  finally
    FPortOpenErrorHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.CallPortCloseHandlers;
var
  i: integer;
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortCloseHandlerListCS.Enter;
  try
    for i := 0 to FPortCloseHandlerList.Count - 1 do
      try
        if Assigned(FPortCloseHandlerList.Items[i]) then
          FPortCloseHandlerList.Items[i]();
      except
      end;
  finally
    FPortCloseHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.CallPortCloseErrorHandlers;
var
  i: integer;
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortCloseErrorHandlerListCS.Enter;
  try
    for i := 0 to FPortCloseErrorHandlerList.Count - 1 do
      try
        if Assigned(FPortCloseErrorHandlerList.Items[i]) then
          FPortCloseErrorHandlerList.Items[i]();
      except
      end;
  finally
    FPortCloseErrorHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.CallPortDisconnectedHandlers;
var
  i: integer;
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FPortDisconnectedHandlerListCS.Enter;
  try
    for i := 0 to FPortDisconnectedHandlerList.Count - 1 do
      try
        if Assigned(FPortDisconnectedHandlerList.Items[i]) then
          FPortDisconnectedHandlerList.Items[i]();
      except
      end;
  finally
    FPortDisconnectedHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.CallReadErrorHandlers;
var
  i: integer;
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FReadErrorHandlerListCS.Enter;
  try
    for i := 0 to FReadErrorHandlerList.Count - 1 do
      try
        if Assigned(FReadErrorHandlerList.Items[i]) then
          FReadErrorHandlerList.Items[i]();
      except
      end;
  finally
    FReadErrorHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.CallWriteErrorHandlers;
var
  i: integer;
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FWriteErrorHandlerListCS.Enter;
  try
    for i := 0 to FWriteErrorHandlerList.Count - 1 do
    try
      if Assigned(FWriteErrorHandlerList.Items[i]) then
        FWriteErrorHandlerList.Items[i]();
    except
    end;
  finally
    FWriteErrorHandlerListCS.Leave;
  end;
end;

procedure TpSCADACustomCommPort.DoPortOpen;
begin
  if Assigned(FOnPortOpen) then
    FOnPortOpen(Self);
end;

procedure TpSCADACustomCommPort.DoPortOpenError;
begin
  if Assigned(FOnPortOpenError) then
    FOnPortOpenError(Self);
end;

procedure TpSCADACustomCommPort.DoPortClose;
begin
  if Assigned(FOnPortClose) then
    FOnPortClose(Self);
end;

procedure TpSCADACustomCommPort.DoPortCloseError;
begin
  if Assigned(FOnPortCloseError) then
    FOnPortCloseError(Self);
end;

procedure TpSCADACustomCommPort.DoPortDisconnected;
begin
  if Assigned(FOnPortDisconnected) then
    FOnPortDisconnected(Self);
end;

procedure TpSCADACustomCommPort.DoReadError;
begin
  if Assigned(FOnReadError) then
    FOnReadError(Self);
end;

procedure TpSCADACustomCommPort.DoWriteError;
begin
  if Assigned(FOnWriteError) then
    FOnWriteError(Self);
end;

function TpSCADACustomCommPort.ReallyActive: boolean;
begin
  Result := False;
end;


procedure TpSCADACustomCommPort.Begin_IO_Operation;
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;
  FOperationCS.Enter;
end;


procedure TpSCADACustomCommPort.End_IO_Operation;
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  if res = 1 then exit;

  FOperationCS.Leave;
end;


function TpSCADACustomCommPort.Read(var buffer: TBytes;
  bytes_to_read, max_retries: longint; var bytes_read: longint): longint;
begin
  Result := Read(@buffer[0], min(Length(buffer), bytes_to_read), max_retries, bytes_read);
end;


function TpSCADACustomCommPort.Write(buffer: TBytes; max_retries: longint;
  var bytes_written: longint): longint;
begin
  Result := Write(@buffer[0], Length(buffer), max_retries, bytes_written);
end;


procedure TpSCADACustomCommPort.Loaded;
begin
  inherited Loaded;
  SetActive(FActiveInLoading);
end;


constructor TpSCADACustomCommPort.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPortBeingDestroyed := 0;
  FExclusiveDevice := True;

  FOperationCS := TCriticalSection.Create;
  FLockCS := TCriticalSection.Create;

  FPortOpenHandlerList := TpSCADANotificationList.Create;
  FPortOpenErrorHandlerList := TpSCADANotificationList.Create;
  FPortCloseHandlerList := TpSCADANotificationList.Create;
  FPortCloseErrorHandlerList := TpSCADANotificationList.Create;
  FPortDisconnectedHandlerList := TpSCADANotificationList.Create;
  FWriteErrorHandlerList := TpSCADANotificationList.Create;
  FReadErrorHandlerList := TpSCADANotificationList.Create;

  FPortOpenHandlerListCS := TCriticalSection.Create;
  FPortOpenErrorHandlerListCS := TCriticalSection.Create;
  FPortCloseHandlerListCS := TCriticalSection.Create;
  FPortCloseErrorHandlerListCS := TCriticalSection.Create;
  FPortDisconnectedHandlerListCS := TCriticalSection.Create;
  FWriteErrorHandlerListCS := TCriticalSection.Create;
  FReadErrorHandlerListCS := TCriticalSection.Create;
end;


destructor TpSCADACustomCommPort.Destroy;
begin
  InternalClose;

  InterLockedExchange(FPortBeingDestroyed, 1);

  TThread.RemoveQueuedEvents(@DoPortOpen);
  TThread.RemoveQueuedEvents(@DoPortOpenError);
  TThread.RemoveQueuedEvents(@DoPortClose);
  TThread.RemoveQueuedEvents(@DoPortCloseError);
  TThread.RemoveQueuedEvents(@DoPortDisconnected);
  TThread.RemoveQueuedEvents(@DoReadError);
  TThread.RemoveQueuedEvents(@DoWriteError);

  FreeAndNil(FPortOpenHandlerListCS);
  FreeAndNil(FPortOpenErrorHandlerListCS);
  FreeAndNil(FPortCloseHandlerListCS);
  FreeAndNil(FPortCloseErrorHandlerListCS);
  FreeAndNil(FPortDisconnectedHandlerListCS);
  FreeAndNil(FWriteErrorHandlerListCS);
  FreeAndNil(FReadErrorHandlerListCS);

  FreeAndNil(FPortOpenHandlerList);
  FreeAndNil(FPortOpenErrorHandlerList);
  FreeAndNil(FPortCloseHandlerList);
  FreeAndNil(FPortCloseErrorHandlerList);
  FreeAndNil(FPortDisconnectedHandlerList);
  FreeAndNil(FWriteErrorHandlerList);
  FreeAndNil(FReadErrorHandlerList);

  inherited Destroy;
end;


procedure TpSCADACustomCommPort.Lock;
begin
  if Assigned(FLockCS) then
    FLockCS.Acquire
  else
    raise EAccessViolation.Create('FLockCS = nil');
end;


procedure TpSCADACustomCommPort.Unlock;
begin
  if Assigned(FLockCS) then
    FLockCS.Release
  else
    raise EAccessViolation.Create('FLockCS = nil');
end;


procedure TpSCADACustomCommPort.RefreshLastOSError;
{$IFNDEF FPC}
{$IF defined(WIN32) or defined(WIN64)}
var
  buffer:PAnsiChar;
{$IFEND}
{$ENDIF}
begin
{$IFDEF FPC}
  InterLockedExchange(FLastOSErrorNumber, GetLastOSError);
  FLastOSErrorMessage:=SysErrorMessage(FLastOSErrorNumber);
{$ELSE}
  {$IF defined(WIN32) or defined(WIN64)}
  FLastOSErrorNumber:=GetLastError;
  GetMem(buffer, 512);
  if FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM,nil,FLastOSErrorNumber,LANG_NEUTRAL,Buffer,512,nil)<>0 then begin
    FLastOSErrorMessage:=Buffer;
    FreeMem(buffer);
  end else
    FLastOSErrorMessage:=SFaultGettingLastOSError;
  {$IFEND}
{$ENDIF}
end;


function TpSCADACustomCommPort.PortSettingsOK: boolean;
begin
  Result := False;
end;


function TpSCADACustomCommPort.BeingDestroyed: boolean;
var
  res: cardinal = 0;
begin
  InterLockedExchange(res, FPortBeingDestroyed);
  Result := res = 1;
end;


procedure TpSCADACustomCommPort.DoExceptionIfActive;
begin
  if ReallyActive then
    Exception.Create(SPascalSCADA_CannotChangeSettingsWhileActive);
end;


end.
