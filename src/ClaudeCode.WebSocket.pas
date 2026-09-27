unit ClaudeCode.WebSocket;

{ Minimal RFC 6455 WebSocket server on top of Indy, bound to loopback only.
  Each client runs in its own Indy thread; OnMessage is raised in that thread.
  IWsConnection.Send is thread-safe. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  IdGlobal, IdContext, IdTCPServer, IdSocketHandle;

type
  IWsConnection = interface
    ['{6A2D2C55-1F4B-4C8E-9C1A-2E7B2B8D4F10}']
    function Send(const Text: string): Boolean;
    function IsOpen: Boolean;
    function GetId: Integer;
    property Id: Integer read GetId;
  end;

  TWsMessageEvent = procedure(const Conn: IWsConnection; const Text: string) of object;
  TWsConnEvent = procedure(const Conn: IWsConnection) of object;

  TWsServer = class
  private
    FServer: TIdTCPServer;
    FPort: Integer;
    FAuthToken: string;
    FLock: TCriticalSection;
    FConnections: TList<IWsConnection>;
    FNextId: Integer;
    FOnMessage: TWsMessageEvent;
    FOnConnect: TWsConnEvent;
    FOnDisconnect: TWsConnEvent;
    procedure ServerExecute(AContext: TIdContext);
    function Handshake(AContext: TIdContext): Boolean;
    procedure ReadLoop(AContext: TIdContext; const Conn: IWsConnection);
    function TryBind(Port: Integer; WithIPv6: Boolean): Boolean;
  public
    constructor Create(const AuthToken: string);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    function Broadcast(const Text: string): Integer;
    function ConnectionCount: Integer;
    property Port: Integer read FPort;
    property OnMessage: TWsMessageEvent read FOnMessage write FOnMessage;
    property OnConnect: TWsConnEvent read FOnConnect write FOnConnect;
    property OnDisconnect: TWsConnEvent read FOnDisconnect write FOnDisconnect;
  end;

implementation

uses
  System.Hash, System.NetEncoding, ClaudeCode.Utils;

const
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  AUTH_HEADER = 'x-claude-code-ide-authorization';
  MAX_MESSAGE = 64 * 1024 * 1024;

  OP_CONT = $0;
  OP_TEXT = $1;
  OP_BINARY = $2;
  OP_CLOSE = $8;
  OP_PING = $9;
  OP_PONG = $A;

type
  TWsConnection = class(TInterfacedObject, IWsConnection)
  private
    FContext: TIdContext;
    FId: Integer;
    FOpen: Boolean;
    FWriteLock: TCriticalSection;
  public
    constructor Create(AContext: TIdContext; AId: Integer);
    destructor Destroy; override;
    function SendFrame(Opcode: Byte; const Payload: TIdBytes): Boolean;
    function Send(const Text: string): Boolean;
    function IsOpen: Boolean;
    function GetId: Integer;
    procedure MarkClosed;
  end;

function BuildFrame(Opcode: Byte; const Payload: TIdBytes): TIdBytes;
var
  Len, HdrLen, I: Integer;
begin
  Len := Length(Payload);
  if Len < 126 then
    HdrLen := 2
  else if Len <= $FFFF then
    HdrLen := 4
  else
    HdrLen := 10;
  SetLength(Result, HdrLen + Len);
  Result[0] := $80 or Opcode;
  if Len < 126 then
    Result[1] := Len
  else if Len <= $FFFF then
  begin
    Result[1] := 126;
    Result[2] := (Len shr 8) and $FF;
    Result[3] := Len and $FF;
  end
  else
  begin
    Result[1] := 127;
    for I := 0 to 7 do
      Result[2 + I] := (UInt64(Len) shr (8 * (7 - I))) and $FF;
  end;
  if Len > 0 then
    Move(Payload[0], Result[HdrLen], Len);
end;

{ TWsConnection }

constructor TWsConnection.Create(AContext: TIdContext; AId: Integer);
begin
  inherited Create;
  FContext := AContext;
  FId := AId;
  FOpen := True;
  FWriteLock := TCriticalSection.Create;
end;

destructor TWsConnection.Destroy;
begin
  FWriteLock.Free;
  inherited;
end;

function TWsConnection.GetId: Integer;
begin
  Result := FId;
end;

function TWsConnection.IsOpen: Boolean;
begin
  FWriteLock.Enter;
  try
    Result := FOpen;
  finally
    FWriteLock.Leave;
  end;
end;

procedure TWsConnection.MarkClosed;
begin
  FWriteLock.Enter;
  try
    FOpen := False;
    FContext := nil;
  finally
    FWriteLock.Leave;
  end;
end;

function TWsConnection.SendFrame(Opcode: Byte; const Payload: TIdBytes): Boolean;
begin
  Result := False;
  FWriteLock.Enter;
  try
    if not FOpen or (FContext = nil) then
      Exit;
    try
      FContext.Connection.IOHandler.Write(BuildFrame(Opcode, Payload));
      Result := True;
    except
      FOpen := False;
    end;
  finally
    FWriteLock.Leave;
  end;
end;

function TWsConnection.Send(const Text: string): Boolean;
begin
  Result := SendFrame(OP_TEXT, TIdBytes(TEncoding.UTF8.GetBytes(Text)));
end;

{ TWsServer }

constructor TWsServer.Create(const AuthToken: string);
begin
  inherited Create;
  FAuthToken := AuthToken;
  FLock := TCriticalSection.Create;
  FConnections := TList<IWsConnection>.Create;
end;

destructor TWsServer.Destroy;
begin
  Stop;
  FConnections.Free;
  FLock.Free;
  inherited;
end;

function TWsServer.TryBind(Port: Integer; WithIPv6: Boolean): Boolean;
var
  B: TIdSocketHandle;
begin
  FServer.Bindings.Clear;
  B := FServer.Bindings.Add;
  B.IPVersion := Id_IPv4;
  B.IP := '127.0.0.1';
  B.Port := Port;
  if WithIPv6 then
  begin
    B := FServer.Bindings.Add;
    B.IPVersion := Id_IPv6;
    B.IP := '::1';
    B.Port := Port;
  end;
  try
    FServer.Active := True;
    Result := True;
  except
    try
      FServer.Active := False;
    except
    end;
    Result := False;
  end;
end;

procedure TWsServer.Start;
var
  Attempt, Port: Integer;
begin
  if (FServer <> nil) and FServer.Active then
    Exit;
  if FServer = nil then
  begin
    FServer := TIdTCPServer.Create(nil);
    FServer.OnExecute := ServerExecute;
  end;
  Randomize;
  for Attempt := 1 to 40 do
  begin
    Port := 10000 + Random(50000);
    // Prefer dual-stack loopback ("localhost" may resolve to ::1), fall back to IPv4 only.
    if TryBind(Port, True) or TryBind(Port, False) then
    begin
      FPort := Port;
      Exit;
    end;
  end;
  raise Exception.Create('Claude Code: could not bind a local WebSocket port');
end;

procedure TWsServer.Stop;
begin
  if FServer = nil then
    Exit;
  try
    FServer.Active := False;
  except
  end;
  FreeAndNil(FServer);
  FLock.Enter;
  try
    FConnections.Clear;
  finally
    FLock.Leave;
  end;
  FPort := 0;
end;

function TWsServer.ConnectionCount: Integer;
begin
  FLock.Enter;
  try
    Result := FConnections.Count;
  finally
    FLock.Leave;
  end;
end;

function TWsServer.Broadcast(const Text: string): Integer;
var
  Snapshot: TArray<IWsConnection>;
  C: IWsConnection;
begin
  FLock.Enter;
  try
    Snapshot := FConnections.ToArray;
  finally
    FLock.Leave;
  end;
  Result := 0;
  for C in Snapshot do
    if C.Send(Text) then
      Inc(Result);
end;

function TWsServer.Handshake(AContext: TIdContext): Boolean;
var
  Line, Key, Accept, Proto, Response: string;
  Headers: TDictionary<string, string>;
  P: Integer;

  procedure Reject(const Status: string);
  begin
    Log('WebSocket handshake rejected: ' + Status);
    AContext.Connection.IOHandler.Write('HTTP/1.1 ' + Status + #13#10 +
      'Content-Length: 0'#13#10'Connection: close'#13#10#13#10);
  end;

begin
  Result := False;
  AContext.Connection.IOHandler.ReadTimeout := 10000;
  Headers := TDictionary<string, string>.Create;
  try
    Line := AContext.Connection.IOHandler.ReadLn; // request line
    if not Line.StartsWith('GET ', True) then
    begin
      Reject('400 Bad Request');
      Exit;
    end;
    repeat
      Line := AContext.Connection.IOHandler.ReadLn;
      if Line = '' then
        Break;
      P := Pos(':', Line);
      if P > 0 then
        Headers.AddOrSetValue(LowerCase(Trim(Copy(Line, 1, P - 1))), Trim(Copy(Line, P + 1, MaxInt)));
    until False;

    if not Headers.TryGetValue(AUTH_HEADER, Line) or (Line <> FAuthToken) then
    begin
      Reject('401 Unauthorized');
      Exit;
    end;
    if not Headers.TryGetValue('upgrade', Line) or not SameText(Line, 'websocket') or
       not Headers.TryGetValue('sec-websocket-key', Key) then
    begin
      Reject('400 Bad Request');
      Exit;
    end;

    Accept := TNetEncoding.Base64.EncodeBytesToString(THashSHA1.GetHashBytes(Key + WS_GUID));
    Response := 'HTTP/1.1 101 Switching Protocols'#13#10 +
      'Upgrade: websocket'#13#10 +
      'Connection: Upgrade'#13#10 +
      'Sec-WebSocket-Accept: ' + Accept + #13#10;
    if Headers.TryGetValue('sec-websocket-protocol', Proto) and (Proto <> '') then
    begin
      P := Pos(',', Proto);
      if P > 0 then
        Proto := Trim(Copy(Proto, 1, P - 1));
      Response := Response + 'Sec-WebSocket-Protocol: ' + Proto + #13#10;
    end;
    Response := Response + #13#10;
    AContext.Connection.IOHandler.Write(Response);
    AContext.Connection.IOHandler.ReadTimeout := IdTimeoutInfinite;
    Result := True;
  finally
    Headers.Free;
  end;
end;

procedure TWsServer.ReadLoop(AContext: TIdContext; const Conn: IWsConnection);
var
  Hdr, Ext, Mask, Payload, Msg: TIdBytes;
  Fin, Masked: Boolean;
  Opcode, MsgOpcode: Byte;
  Len: Int64;
  I: Integer;
  Impl: TWsConnection;
begin
  Impl := Conn as TWsConnection;
  MsgOpcode := OP_TEXT;
  SetLength(Msg, 0);
  while AContext.Connection.Connected do
  begin
    AContext.Connection.IOHandler.ReadBytes(Hdr, 2, False);
    Fin := (Hdr[0] and $80) <> 0;
    Opcode := Hdr[0] and $0F;
    Masked := (Hdr[1] and $80) <> 0;
    Len := Hdr[1] and $7F;
    if Len = 126 then
    begin
      AContext.Connection.IOHandler.ReadBytes(Ext, 2, False);
      Len := (Int64(Ext[0]) shl 8) or Ext[1];
    end
    else if Len = 127 then
    begin
      AContext.Connection.IOHandler.ReadBytes(Ext, 8, False);
      Len := 0;
      for I := 0 to 7 do
        Len := (Len shl 8) or Ext[I];
    end;
    if (Len < 0) or (Len > MAX_MESSAGE) or (Length(Msg) + Len > MAX_MESSAGE) then
      raise Exception.Create('WebSocket frame too large');
    if Masked then
      AContext.Connection.IOHandler.ReadBytes(Mask, 4, False);
    SetLength(Payload, 0);
    if Len > 0 then
      AContext.Connection.IOHandler.ReadBytes(Payload, Integer(Len), False);
    if Masked then
      for I := 0 to Integer(Len) - 1 do
        Payload[I] := Payload[I] xor Mask[I and 3];

    case Opcode of
      OP_TEXT, OP_BINARY, OP_CONT:
        begin
          if Opcode <> OP_CONT then
          begin
            MsgOpcode := Opcode;
            Msg := Payload;
          end
          else
            Msg := Msg + Payload;
          if Fin then
          begin
            if (MsgOpcode = OP_TEXT) and Assigned(FOnMessage) then
              FOnMessage(Conn, TEncoding.UTF8.GetString(TBytes(Msg)));
            SetLength(Msg, 0);
          end;
        end;
      OP_CLOSE:
        begin
          Impl.SendFrame(OP_CLOSE, Payload);
          Exit;
        end;
      OP_PING:
        Impl.SendFrame(OP_PONG, Payload);
      OP_PONG:
        ;
    end;
  end;
end;

procedure TWsServer.ServerExecute(AContext: TIdContext);
var
  Impl: TWsConnection;
  Conn: IWsConnection;
begin
  try
    if not Handshake(AContext) then
    begin
      AContext.Connection.Disconnect;
      Exit;
    end;
    Impl := TWsConnection.Create(AContext, AtomicIncrement(FNextId));
    Conn := Impl;
    FLock.Enter;
    try
      FConnections.Add(Conn);
    finally
      FLock.Leave;
    end;
    try
      if Assigned(FOnConnect) then
        FOnConnect(Conn);
      ReadLoop(AContext, Conn);
    finally
      Impl.MarkClosed;
      FLock.Enter;
      try
        FConnections.Remove(Conn);
      finally
        FLock.Leave;
      end;
      if Assigned(FOnDisconnect) then
        FOnDisconnect(Conn);
    end;
  except
    // Connection errors (client gone, server stopping) end this session quietly.
  end;
  try
    AContext.Connection.Disconnect;
  except
  end;
end;

end.
