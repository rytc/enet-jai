
// @TODO is this just going to be a native port or a reimagining/reimplementation?

// @TODO decide on u32 vs regular ints

// @TODO this might not be good, the initial value is invalid if this module hasn't been initialized 
HOST_ANY : in6_addr;
Socket :: #type SOCKET;

Address :: struct {
  host : in6_addr;
  port : u16;
  sin6_scope_id : u16;
}

Peer :: struct {

}

Host :: struct {
  peers : [] Peer;
  socket : Socket;
  address : Address;
  received_address : Address;
  random_seed : u32;
  channel_limit : u32;
  incoming_bandwidth : u32;
  outgoing_bandwidth : u32;
  mtu : u32;
  duplicate_peers : u32;
  maximum_packet_size : u32;
  maximum_waiting_data : u32;
}

Packet_Flags :: enum_flags u16 {
  RELIABLE;
  UNSEQUENCED;
  NO_ALLOCATE;
  UNRELIABLE_FRAGMENT;
  SENT;
}

Packet :: struct {
  ref_count : u32;
  flags : Packet_Flags;
  data : *u8;
  data_length: u32;
  user_data : *Any;
}

initialize :: () -> bool {
  #if OS == .WINDOWS {
    version : u16 = (1 << 8) | 1;
    wsa_data : WSAData;

    if WSAStartup(version, *wsa_data) {
      log_error("Failed to initialize enet: Failed to startup WSA\n");
      return false;
    }

    if wsa_data.wVersion & 1 != 1 || wsa_data.wVersion >> 8 != 1 {
      log_error("Failed to initialize enet: Requested WSA version is % but got %\n", version, wsa_data.wVersion);
      WSACleanup();
      return false;
    }
  }

  HOST_ANY = in6addr_any; 

  // No initialization needed for unix

  return true;
}

deinitialize :: () {
  #if OS == .WINDOWS {
    WSACleanup();
  }

  // No deinitialization needed for unix
}

host_create :: (address: *Address, peer_count: int, channel_limit: u32, incoming_bandwidth: u32, outgoing_bandwidth: u32) -> *Host, bool {
  host : *Host;

  if peer_count < 0 || peer_count > PROTOCOL_MAXIMUM_PEER_ID {
    log_error("Invalid peer count 0 < % < %", peer_count, PROTOCOL_MAXIMUM_PEER_ID);
    return host, false; 
  }

  // @TODO Not sure if we should actually heap allocate this? It is a big struct...
  host = New(Host);

  host.peers = NewArray(peer_count, Peer);
  
  host.socket = socket_create();

  if host.socket != INVALID_SOCKET set_socket_options(host.socket, .IPV6_V6ONLY, 0);

  if host.socket == INVALID_SOCKET || (address != null && socket_bind(host.socket, address) == false) {
    log_error("Failed to create and bind socket\n");

    socket_destroy(host.socket);
    free(host.peers.data);
    free(host);

    return host, false;
  }

  set_socket_options(host.socket, .NONEBLOCK, 1);
  set_socket_options(host.socket, .BROADCAST, 1);
  set_socket_options(host.socket, .RECEIVE_BUFF, HOST_RECEIVE_BUFFER_SIZE);
  set_socket_options(host.socket, .SEND_BUFF, HOST_SEND_BUFFER_SIZE);
  set_socket_options(host.socket, .IPV6_V6ONLY, 0);

  
  if address != null && !get_socket_address(host.socket, *host.address) {
    host.address = <<address;
  }

  if channel_limit == 0 || channel_limit > PROTOCOL_MAXIMUM_CHANNEL_COUNT {
    channel_limit = PROTOCOL_MAXIMUM_CHANNEL_COUNT;
  }

  host.random_seed = (cast(u32)host) % U32_MAX;
  host.random_seed += xx random_seed(); 
  host.random_seed = (host.random_seed << 16) | (host.random_seed >> 16);
  host.channel_limit = channel_limit;
  host.incoming_bandwidth = incoming_bandwidth;
  host.outgoing_bandwidth = outgoing_bandwidth;
  host.mtu = HOST_DEFAULT_MTU;
  host.received_address.host = HOST_ANY;
  host.received_address.port = 0;
  host.duplicate_peers = PROTOCOL_MAXIMUM_PEER_ID;
  host.maximum_packet_size = HOST_DEFAULT_MAXIMUM_PACKET_SIZE;
  host.maximum_waiting_data = HOST_DEFAULT_MAXIMUM_WAITING_DATA; // @TODO these could probably be set on the struct?

  return host, true;
}

host_destroy :: (host: *Host) {
  socket_destroy(host.socket);
  free(host.peers.data);
  free(host);
}

create_packet :: (data : *void, data_length : u32, flags : Packet_Flags = .RELIABLE) -> *Packet {
  packet : *Packet;

  // @TODO :alloc better allocation strategy?
  if flags & .NO_ALLOCATE {
    packet = New(Packet);
    packet.data = xx data;
  } else {
    packet = alloc(size_of(Packet) + data_length);
    packet.data = cast(*u8)(packet) + size_of(Packet);
    memcpy(packet.data, data, data_length);
  }

  packet.flags = flags;
  packet.data_length = data_length;

  return packet;
}

create_packet :: (data: *$T, flags: Packet_Flags = .RELIABLE) -> *Packet #expand {
  return create_packet(xx data, xx size_of(T), flags);
}

create_packet :: (data: []u8, flags: Packet_Flags = .RELIABLE) -> *Packet #expand {
  return create_packet(xx data.data, xx data.count, flags);
}

destroy_packet :: (packet: *Packet) {
  free(packet);
}

#scope_file
#import "Basic";
#import "Socket";
#import "Math"; // U32_MAX

#if OS == .WINDOWS {
  Windows :: #import "Windows"; // timeGetTime
}

PROTOCOL_MAXIMUM_PEER_ID       :: 0xFFF;
PROTOCOL_MAXIMUM_CHANNEL_COUNT :: 255;

HOST_RECEIVE_BUFFER_SIZE          :: 256 * 1024;
HOST_SEND_BUFFER_SIZE             :: 256 * 1024;
HOST_DEFAULT_MTU                  :: 1400;
HOST_DEFAULT_MAXIMUM_PACKET_SIZE  :: 32 * 1024 * 1024;
HOST_DEFAULT_MAXIMUM_WAITING_DATA :: 32 * 1024 * 1024;

Socket_Options :: enum {
  NONEBLOCK;
  BROADCAST;
  RECEIVE_BUFF;
  SEND_BUFF;
  IPV6_V6ONLY;
}

socket_create :: () -> Socket {
  return socket(PF_INET6, .DGRAM, 0);
}

socket_destroy :: (socket: Socket) {
  #if OS == .WINDOWS {
    closesocket(socket);
  } else {
    close(socket);
  }
}

set_socket_options :: (socket: Socket, options: Socket_Options, value: s32) -> bool {
  result : int;

  if options == {
    case .NONEBLOCK;
      #if OS == .WINDOWS {
        result = ioctlsocket(socket, FIONBIO, cast(*u32)*value);
      } else {
        other := fcntl(socket, F_GETFL) & ~O_NONBLOCK;
        result = fcntl(socket, F_SETFL, ifx value then O_NONBLOCK else 0 | other);
      }
    case .BROADCAST;
      result = setsockopt(socket, SOL_SOCKET, SO_BROADCAST, cast(*u8)*value, size_of(s32));
    case .RECEIVE_BUFF;
      result = setsockopt(socket, SOL_SOCKET, SO_RCVBUF, cast(*u8)*value, size_of(s32));
    case .SEND_BUFF;
      result = setsockopt(socket, SOL_SOCKET, SO_SNDBUF, cast(*u8)*value, size_of(s32));
    case .IPV6_V6ONLY;
      result = setsockopt(socket, xx IPPROTO.IPV6, IPV6_V6ONLY, cast(*u8)*value, size_of(s32));
  }

  if result == -1 return false;

  return true;
}

socket_bind :: (socket: Socket, address: *Address) -> bool {
  sin : sockaddr_in6;

  if address {
    sin.sin6_port = htons(address.port);
    sin.sin6_addr = address.host;
    sin.sin6_scope_id = address.sin6_scope_id;
  } else {
    sin.sin6_port = 0;
    sin.sin6_addr = HOST_ANY;
    sin.sin6_scope_id = 0;
  }
  
  return ifx bind(socket, cast(*sockaddr)*sin, size_of(sockaddr_in6)) then true else false;
}

get_socket_address :: (socket: Socket, address: *Address) -> bool {
  sin : sockaddr_in6;
  sin_len :s32= xx size_of(sockaddr_in6);

  if getsockname(socket, cast(*sockaddr)*sin, *sin_len) == -1 return false;

  address.host = sin.sin6_addr;
  address.port = htons(sin.sin6_port);
  address.sin6_scope_id = xx sin.sin6_scope_id;

  return true;
}

random_seed :: () -> u64 {
  #if OS == .WINDOWS {
    return cast(u64)Windows.timeGetTime();
  } else {
    return cast(u64)time(null);
  }
}
