
Socket :: #type SOCKET;

Socket_Options :: enum {
  NONEBLOCK;
  BROADCAST;
  RECEIVE_BUFF;
  SEND_BUFF;
  IPV6_V6ONLY;
}

Socket_Wait :: enum_flags u8 {
  NONE;
  SEND;
  RECEIVE;
  INTERRUPT;
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

socket_wait :: (socket: Socket, condition: *Socket_Wait, timeout: s64) -> int {
  log_error("TODO: socket wait not implemented\n");
  #if OS == .WINDOWS {

  } else #if OS == .UNIX {

  }

  return -1;
}
