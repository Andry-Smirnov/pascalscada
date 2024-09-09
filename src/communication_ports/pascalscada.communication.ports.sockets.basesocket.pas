unit pascalscada.communication.ports.sockets.basesocket;


{$mode objfpc}{$H+}


interface


uses
  Classes,
  SysUtils,
  Sockets,
  pascalscada.communication.ports.basecommport,
  pascalscada.multithreading.core_affinity_threads,
  pascalscada.multithreading.event_synchronization,
  pascalscada.multithreading.message_queue;


type
  TConnectEvent = procedure(var Ok: boolean) of object;
  TpSCADASocketType = (stUndefined, stTCP, stUDP);

{$IF defined(FPC) AND (FPC_FULLVERSION >= 20400)}
  {$IF defined(WIN32) or defined(WIN64)}
  TpSCADASockLen = tOS_INT;
  {$ELSE}
  TpSCADASockLen = TSockLen;
  {$IFEND}
{$ELSE}
  TpSCADASockLen = LongInt;
{$IFEND}


{ TpSCADAConnectSocketThread }

  TpSCADAConnectSocketThread = class(TpSCADACoreAffinityThread)
  private
    FActive: Boolean;
    FCheckSocket: TConnectEvent;
    FConnectSocket: TConnectEvent;
    FDisconnectSocket: TConnectEvent;
    FEnd: TpSCADAThreadSyncEvent;
    FReconnectSocket: TConnectEvent;
    FMessageQueue: TpSCADAThreadSafeMessageQueue;

    FAutoReconnect: integer;
    FReconnectInterval: integer;
    FReconnectRetries: integer;

    function GetEnableAutoReconnect: Boolean;

    function GetReconnectInterval: integer;
    function GetReconnectRetries: integer;

    procedure SetReconnectInterval(aValue: integer);
    procedure SetEnableAutoReconnect(aValue: Boolean);
    procedure SetReconnectRetries(AValue: integer);
  protected
    procedure Execute; override;
  public
    constructor Create;
    procedure Connect;
    procedure Disconnect;
    procedure NotifyDisconnect;
    procedure WaitEnd;
    procedure StopAutoReconnect;
  published
    property ConnectSocket: TConnectEvent read FConnectSocket write FConnectSocket;
    property ReconnectSocket: TConnectEvent read FReconnectSocket write FReconnectSocket;
    property DisconnectSocket: TConnectEvent read FDisconnectSocket write FDisconnectSocket;
    property CheckSocket: TConnectEvent read FCheckSocket write FCheckSocket;

    property EnableAutoReconnect: Boolean read GetEnableAutoReconnect write SetEnableAutoReconnect;
    property ReconnectInterval: integer read GetReconnectInterval write SetReconnectInterval;
  end;


  { TpSCADACustomSocket }

  TpSCADACustomSocket = class(TpSCADACustomCommPort)
  private
    FConnectThread: TpSCADAConnectSocketThread;
    FExclusiveReaded: Boolean;

    function GetEnableAutoReconect: Boolean;
    function GetReconnectInterval: integer;
    procedure setEnableAutoReconnect(AValue: Boolean);
    procedure SetExclusive(AValue: Boolean);
    procedure SetIPv4Address(AValue: ansistring);
    procedure SetPortNumber(AValue: word);
    procedure SetReconnectInterval(AValue: integer);
    procedure SetTimeout(AValue: longword);
  protected
    FIPv4Address: ansistring;
    FPortNumber: word;
    FTimeout: longword;
    FSocket: Tsocket;
    FSocketType: TpSCADASocketType;

    procedure CallPortCloseHandlers; override;
    procedure CallPortCloseErrorHandlers; override;
    procedure CallPortDisconnectedHandlers; override;
    procedure CallPortOpenHandlers; override;
    procedure CallPortOpenErrorHandlers; override;
    procedure CallReadErrorHandlers; override;
    procedure CallWriteErrorHandlers; override;
    function Close: Boolean; override;
    procedure Loaded; override;
    function PortSettingsOK: Boolean; override;
    function Open: Boolean; override;

    //: Enables the auto reconnection if a connection is lost or failed.
    property EnableAutoReconnect: Boolean read GetEnableAutoReconect write setEnableAutoReconnect default True;
    //: Tells if the communication port is exclusive (if true, avoid it to open in design time).
    property ExclusiveDevice: Boolean read FExclusiveDevice write SetExclusive default True;
    //: IPv4 address of the server to connect.
    property IPv4Address: ansistring read FIPv4Address write SetIPv4Address nodefault;
    //: Server port to connect. To use Modbus, set this to 502 and to use Siemens ISOTCP set it to 102.
    property Port: word read FPortNumber write SetPortNumber default 102;
    //: Time to retry a lost connection in milliseconds.
    property ReconnectRetryInterval: integer read GetReconnectInterval write SetReconnectInterval default 5000;
    //: Timeout in milliseconds to I/O operations.
    property Timeout: longword read FTimeout write SetTimeout default 1000;
  protected
    procedure CheckSocket(var Ok: Boolean); virtual; abstract;
    procedure CloseMySocket(var Ok: Boolean); virtual; abstract;
    procedure ConnectSocket(var Ok: Boolean); virtual; abstract;
    function GetSocketType: TpSCADASocketType; virtual; abstract;
    function InvalidSocket: Tsocket; virtual; abstract;
    procedure ReconnectSocket(var Ok: Boolean); virtual; abstract;
    function CheckConnection(var CommResult: LongInt; var incRetries: Boolean): Boolean; virtual; abstract;
    function connect_with_timeout(sock: Tsocket; address: PSockAddr;
      address_len: TpSCADASockLen; ConnectTimeout: LongInt): LongInt; virtual; abstract;
    function connect_without_timeout(sock: Tsocket; address: PSockAddr;
      address_len: TpSCADASockLen): LongInt; virtual; abstract;
    function setblockingmode(fd: TSocket; mode: LongInt): LongInt; virtual; abstract;
    function socket_recv(buf: PByte; len: Cardinal; flags, recv_timeout: LongInt): LongInt; virtual; abstract;
    function socket_send(buf: PByte; len: Cardinal; flags, send_timeout: LongInt): LongInt; virtual; abstract;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function Read(buffer: PByte; BufferSize, MaxRetries: LongInt;
      var BytesRead: LongInt): LongInt; override; overload;
    function ReallyActive: Boolean; override;
    function Write(buffer: PByte; buffer_size, max_retries: LongInt;
      var bytes_written: LongInt): LongInt; override; overload;
  end;


const
  MODE_NONBLOCKING = 1;
  MODE_BLOCKING = 0;


resourcestring
  SPascalSCADA_TheAddressIsNotAValidIPv4Address = 'The address "%s" is not a valid IPv4 address';
  SPascalSCADA_InvalidSocketPortNumber = '"%d" is not a valid socket port number';


implementation


uses
  dateutils,
  syncobjs,
  pascalscada.utilities.strings;


function TpSCADAConnectSocketThread.GetEnableAutoReconnect: Boolean;
var
  res: LongInt = 0;
begin
  InterLockedExchange(res, FAutoReconnect);
  Result := res = 1;
end;


function TpSCADAConnectSocketThread.GetReconnectInterval: integer;
begin
  Result := 0;
  InterLockedExchange(Result, FReconnectInterval);
end;


function TpSCADAConnectSocketThread.GetReconnectRetries: integer;
begin
  Result := 0;
  InterLockedExchange(Result, FReconnectRetries);
end;


procedure TpSCADAConnectSocketThread.SetReconnectInterval(aValue: integer);
begin
  InterLockedExchange(FReconnectInterval, aValue);
end;


procedure TpSCADAConnectSocketThread.SetEnableAutoReconnect(aValue: Boolean);
begin
  if aValue then
    InterLockedExchange(FAutoReconnect, 1)
  else
    InterLockedExchange(FAutoReconnect, 0);
end;


procedure TpSCADAConnectSocketThread.SetReconnectRetries(AValue: integer);
begin
  InterLockedExchange(FReconnectRetries, AValue);
end;


procedure TpSCADAConnectSocketThread.Execute;
var
  msg: TpSCADAMsg;
  Ok: Boolean;
  ReconnectTimerRunning: Boolean;
  ReconnectStarted: TDateTime;
  msbetween: int64;
begin
  ReconnectTimerRunning := False;
  ReconnectStarted := now;
  while not Terminated do
    begin
      while FMessageQueue.PeekMessage(msg, 0, 100, True) do
        begin
          Ok := False;
          case msg.MsgID of
            0:  begin
                  FActive := True;
                  if Assigned(FConnectSocket) then
                    begin
                      FConnectSocket(Ok);
                      if (Ok) then
                        ReconnectTimerRunning := False
                      else
                      if (FAutoReconnect = 1) then
                        begin
                          if ReconnectTimerRunning = False then
                            ReconnectStarted := Now;
                          ReconnectTimerRunning := True;
                        end;
                    end;
                end;
            1:  begin
                  if FActive then
                    begin
                      if ReconnectTimerRunning = False then
                        ReconnectStarted := Now;
                      ReconnectTimerRunning := True;
                    end;
                end;
            2:  begin
                  ReconnectTimerRunning := False;
                end;
            3:  begin
                  FActive := False;
                  if Assigned(DisconnectSocket) then
                    DisconnectSocket(Ok);
                  ReconnectTimerRunning := False;
                end;
          end;
        end;

      if FActive then
        begin
          OK := True;
          if assigned(FCheckSocket) then
            FCheckSocket(Ok);
          if not ok then
            begin
              if ReconnectTimerRunning = False then
                ReconnectStarted := Now;
              ReconnectTimerRunning := True;
            end;
        end;

      msbetween := MilliSecondsBetween(now, ReconnectStarted);
      if (FAutoReconnect = 1) and (ReconnectTimerRunning) and
        (msbetween >= ReconnectInterval) then
        begin
          ReconnectStarted := Now;
          Ok := False;
          if Assigned(FReconnectSocket) then
            FReconnectSocket(Ok);
          if Ok then
            ReconnectTimerRunning := False;
        end;

      Sleep(250);
    end;
  FEnd.SetEvent;
end;


constructor TpSCADAConnectSocketThread.Create;
begin
  inherited Create(True);
  FMessageQueue := TpSCADAThreadSafeMessageQueue.Create;
  FEnd := TpSCADAThreadSyncEvent.Create(True, False);
end;


procedure TpSCADAConnectSocketThread.Connect;
var
  msg: PpSCADAMsgPkg;
begin
  msg := GetMem(SizeOf(TpSCADAMsgPkg));
  FillByte(msg^, SizeOf(TpSCADAMsgPkg), 0);
  msg^.Msg.MsgID := 0;
  msg^.Msg.lParam := nil;
  msg^.Msg.wParam := nil;
  msg^.Msg.Priority := False;
  FMessageQueue.PostMessage(msg);
end;


procedure TpSCADAConnectSocketThread.Disconnect;
var
  msg: PpSCADAMsgPkg;
begin
  msg := GetMem(SizeOf(TpSCADAMsgPkg));
  FillByte(msg^, SizeOf(TpSCADAMsgPkg), 0);
  msg^.Msg.MsgID := 3;
  msg^.Msg.lParam := nil;
  msg^.Msg.wParam := nil;
  msg^.Msg.Priority := False;
  FMessageQueue.PostMessage(msg);
end;


procedure TpSCADAConnectSocketThread.NotifyDisconnect;
var
  msg: PpSCADAMsgPkg;
begin
  msg := GetMem(SizeOf(TpSCADAMsgPkg));
  FillByte(msg^, SizeOf(TpSCADAMsgPkg), 0);
  msg^.Msg.MsgID := 1;
  msg^.Msg.lParam := nil;
  msg^.Msg.wParam := nil;
  msg^.Msg.Priority := False;
  FMessageQueue.PostMessage(msg);
end;


procedure TpSCADAConnectSocketThread.WaitEnd;
begin
  while not (FEnd.WaitFor(5) = wrSignaled) do
    CheckSynchronize(5);
end;


procedure TpSCADAConnectSocketThread.StopAutoReconnect;
var
  msg: PpSCADAMsgPkg;
begin
  msg := GetMem(SizeOf(TpSCADAMsgPkg));
  FillByte(msg^, SizeOf(TpSCADAMsgPkg), 0);
  msg^.Msg.MsgID := 2;
  msg^.Msg.lParam := nil;
  msg^.Msg.wParam := nil;
  msg^.Msg.Priority := False;
  FMessageQueue.PostMessage(msg);
end;


{ TpSCADACustomSocket }

function TpSCADACustomSocket.GetEnableAutoReconect: Boolean;
begin
  Result := FConnectThread.EnableAutoReconnect;
end;


function TpSCADACustomSocket.GetReconnectInterval: integer;
begin
  Result := FConnectThread.ReconnectInterval;
end;


procedure TpSCADACustomSocket.setEnableAutoReconnect(AValue: Boolean);
begin
  FConnectThread.EnableAutoReconnect := AValue;
  if AValue = False then
    FConnectThread.StopAutoReconnect;
end;


procedure TpSCADACustomSocket.SetExclusive(AValue: Boolean);
var
  oldstate: Boolean;
begin
  if csReading in ComponentState then
    begin
      FExclusiveReaded := AValue;
      exit;
    end;

  if FExclusiveDevice = AValue then Exit;

  //only at design-time
  if csDesigning in ComponentState then
    begin
      //stores the old state.
      oldstate := Active;
      //close the communication port.
      Active := False;
      //set the new state.
      FExclusiveDevice := AValue;
      //restores the old state.
      Active := oldstate;
    end
  else
    FExclusiveDevice := AValue;
end;


procedure TpSCADACustomSocket.SetIPv4Address(AValue: ansistring);
begin
  DoExceptionIfActive;
  if FIPv4Address = AValue then Exit;
  if IsIPv4Address(AValue) then
    FIPv4Address := AValue
  else
    raise Exception.Create(Format(
      SPascalSCADA_TheAddressIsNotAValidIPv4Address, [AValue]));
end;


procedure TpSCADACustomSocket.SetPortNumber(AValue: word);
begin
  DoExceptionIfActive;
  if FPortNumber = AValue then Exit;
  if (AValue >= 1) then
    FPortNumber := AValue
  else
    raise Exception.Create(Format(SPascalSCADA_InvalidSocketPortNumber, [AValue]));
end;


procedure TpSCADACustomSocket.SetReconnectInterval(AValue: integer);
begin
  FConnectThread.ReconnectInterval := AValue;
end;


procedure TpSCADACustomSocket.SetTimeout(AValue: longword);
begin
  if FTimeout = AValue then Exit;
  InterLockedExchange(FTimeout, AValue);
end;


procedure TpSCADACustomSocket.CallPortCloseHandlers;
begin
  inherited CallPortCloseHandlers;
  TThread.Queue(nil, @DoPortClose);
end;


procedure TpSCADACustomSocket.CallPortCloseErrorHandlers;
begin
  inherited CallPortCloseErrorHandlers;
  TThread.Queue(nil, @DoPortCloseError);
end;


procedure TpSCADACustomSocket.CallPortDisconnectedHandlers;
begin
  inherited CallPortDisconnectedHandlers;
  TThread.Queue(nil, @DoPortDisconnected);
end;


procedure TpSCADACustomSocket.CallPortOpenHandlers;
begin
  inherited CallPortOpenHandlers;
  TThread.Queue(nil, @DoPortOpen);
end;


procedure TpSCADACustomSocket.CallPortOpenErrorHandlers;
begin
  inherited CallPortOpenErrorHandlers;
  TThread.Queue(nil, @DoPortOpenError);
end;


procedure TpSCADACustomSocket.CallReadErrorHandlers;
begin
  inherited CallReadErrorHandlers;
  TThread.Queue(nil, @DoReadError);
end;


procedure TpSCADACustomSocket.CallWriteErrorHandlers;
begin
  inherited CallWriteErrorHandlers;
  TThread.Queue(nil, @DoWriteError);
end;


function TpSCADACustomSocket.Close: Boolean;
begin
  if ([csDesigning] * ComponentState = []) or FExclusiveDevice then
    FConnectThread.Disconnect;
  Result := True;
end;


procedure TpSCADACustomSocket.Loaded;
begin
  FExclusiveDevice := FExclusiveReaded;
  inherited Loaded;
end;


function TpSCADACustomSocket.PortSettingsOK: Boolean;
begin
  Result := IsIPv4Address(FIPv4Address);
end;


function TpSCADACustomSocket.Open: Boolean;
begin
  if ([csDesigning] * ComponentState = []) or FExclusiveDevice then
    FConnectThread.Connect;
  Result := True;
end;


function TpSCADACustomSocket.ReallyActive: Boolean;
begin
  Result := FSocket <> InvalidSocket;
end;


constructor TpSCADACustomSocket.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPortNumber := 102;
  FTimeout := 100;
  FExclusiveDevice := True;
  FSocket := InvalidSocket;
  FSocketType := GetSocketType;

  FConnectThread := TpSCADAConnectSocketThread.Create;
  FConnectThread.EnableAutoReconnect := True;
  FConnectThread.ReconnectInterval := 5000;
  FConnectThread.ConnectSocket := @ConnectSocket;
  FConnectThread.ReconnectSocket := @ReconnectSocket;
  FConnectThread.DisconnectSocket := @CloseMySocket;
  FConnectThread.CheckSocket := @CheckSocket;
  FConnectThread.Start;
end;


destructor TpSCADACustomSocket.Destroy;
begin
  inherited Destroy;
  FConnectThread.Terminate;
  FConnectThread.WaitEnd;
  FreeAndNil(FConnectThread);
end;


function TpSCADACustomSocket.Read(buffer: PByte; BufferSize, MaxRetries: LongInt;
  var BytesRead: LongInt): LongInt;
var
  lidos: LongInt;
  tentativas: Cardinal;
  incretries: Boolean = False;
begin
  Result := iorNone;

  if BeingDestroyed then exit;

  tentativas := 0;
  lidos := 0;

  BytesRead := 0;
  while (BytesRead < BufferSize) and (tentativas < MaxRetries) do
    begin
      try
        lidos := socket_recv(@buffer[BytesRead], BufferSize - BytesRead, 0, FTimeout);
      finally
      end;

      if lidos <= 0 then
        begin
          if not CheckConnection(Result, incretries) then
            begin
              break;
            end;
          if incRetries then
            Inc(tentativas);
        end
      else
        BytesRead := BytesRead + lidos;
    end;

  if BufferSize > BytesRead then
    begin
      if Result = iorNone then
        Result := iorTimeOut;
    end
  else
    Result := BytesRead;
end;


function TpSCADACustomSocket.Write(buffer: PByte; buffer_size, max_retries: LongInt;
  var bytes_written: LongInt): LongInt;
var
  escritos: LongInt;
  tentativas: Cardinal;
  incretries: Boolean = False;
begin
  Result := iorNone;

  if BeingDestroyed then exit;

  tentativas := 0;
  escritos := 0;

  bytes_written := 0;
  while (bytes_written < buffer_size) and (tentativas < max_retries) do
    begin
      try
        escritos := socket_send(@buffer[bytes_written], buffer_size - bytes_written,
          0, FTimeout);
      finally
      end;

      if escritos <= 0 then
        begin
          if not CheckConnection(Result, incretries) then
            break;
          if incRetries then
            Inc(tentativas);
        end
      else
        bytes_written := bytes_written + escritos;
    end;

  if buffer_size > bytes_written then
    begin
      Result := iorTimeOut;
    end
  else
    Result := iorOK;

  if Result < iorOK then
    CallWriteErrorHandlers;
end;


end.
