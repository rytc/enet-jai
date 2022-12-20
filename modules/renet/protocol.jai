PROTOCOL_MAX_PEER_ID       :: 0xFFF;
PROTOCOL_MAX_CHANNEL_COUNT :: 255;
PROTOCOL_MAX_WINDOW_SIZE   :: 65536;
PROTOCOL_MIN_WINDOW_SIZE   :: 4096;
PROTOCOL_MAX_PACKET_COMMANDS :: 32;
PROTOCOL_MAX_MTU             :: 4096;
PROTOCOL_COMMAND_MASK        :u8: 0x0F;
PROTOCOL_FLAG_MASK           :u32: PROTOCOL_FLAG_COMPRESSED | PROTOCOL_FLAG_SENT_TIME;
PROTOCOL_SESSION_SHIFT       :: 12;

PROTOCOL_FLAG_ACKNOWLEDGE :u32: 1 << 7;
PROTOCOL_FLAG_UNSEQUENCED :u32: 1 << 6;
PROTOCOL_FLAG_COMPRESSED  :u32: 1 << 14;
PROTOCOL_FLAG_SENT_TIME   :u32: 1 << 15;

// These get masked with the above flags, so no enum usage /sadge
PROTOCOL_COMMAND_NONE            :: 0;
PROTOCOL_COMMAND_ACKNOWLEDGE     :: 1;
PROTOCOL_COMMAND_CONNECT         :: 2;
PROTOCOL_COMMAND_VERIFY_CONNECT  :: 3;
PROTOCOL_COMMAND_DISCONNECT      :: 4;
PROTOCOL_COMMAND_PING            :: 5;
PROTOCOL_COMMAND_SEND_RELIABLE   :: 6;
PROTOCOL_COMMAND_SEND_UNRELIABLE :: 7;
PROTOCOL_COMMAND_SEND_FRAGMENT   :: 8;
PROTOCOL_COMMAND_SEND_UNSEQUENCED :: 9;
PROTOCOL_COMMAND_BANDWIDTH_LIMIT  :: 10;
PROTOCOL_COMMAND_THROTTLE_CONFIGURE :: 11;
PROTOCOL_COMMAND_SEND_UNRELIABLE_FRAGMENT :: 12;
PROTOCOL_COMMAND_COUNT :: 13;


Protocol_Header :: struct {
  peer_id : u16;
  sent_time : u16;
}

Protocol_Command_Header :: struct {
  command : u32;
  channel_id : u8;
  reliable_seq_number : u16;
}

Protocol_Acknowledge :: struct {
  using header : Protocol_Command_Header;
  received_reliable_seq_number : u16;
  received_sent_time : u16;
}

Protocol_Connect :: struct {
  using header : Protocol_Command_Header;
  outgoing_peer_id : u16;
  incoming_session_id : u8;
  outgoing_session_id : u8;
  mtu : u32;
  window_size : u32;
  channel_count : u32;
  incoming_bandwidth : u32;
  outgoing_bandwidth : u32;
  packet_throttle_interval : u32;
  packet_throttle_acceleration : u32;
  packet_throttle_deceleration : u32;
  connect_id : u32;
  data : u32;
}

Protocol_Verify_Connect :: struct {
  using header : Protocol_Command_Header;
  outgoing_peer_id : u16;
  incoming_session_id : u8;
  outgoing_session_id : u8;
  mtu : u32;
  window_size : u32;
  channel_count : u32;
  incoming_bandwidth : u32;
  outgoing_bandwidth : u32;
  packet_throttle_interval : u32;
  packet_throttle_acceleration : u32;
  packet_throttle_deceleration : u32;
  connect_id : u32;
}

Protocol_Disconnect :: struct {
  using header : Protocol_Command_Header;
  data : u32;
}

Protocol_Ping :: struct {
  using header : Protocol_Command_Header;
}

Protocol_Send_Reliable :: struct {
  using header : Protocol_Command_Header;
  data_length : u16;
}

Protocol_Send_Unreliable :: struct {
  using header : Protocol_Command_Header;
  unreliable_seq_number : u16;
  data_length : u16;
}

Protocol_Send_Fragment :: struct {
  using header : Protocol_Command_Header;
  start_seq_number : u16;
  data_length : u16;
  fragment_count : u32;
  fragment_number : u32;
  total_length : u32;
  fragment_offset : u32;
}

Protocol_Send_Unsequenced :: struct {
  using header : Protocol_Command_Header;
  unsequenced_group : u16;
  data_length : u16;
}

Protocol_Bandwidth_Limit :: struct {
  using header : Protocol_Command_Header;
  incoming_bandwidth : u32;
  outgoing_bandwidth : u32;
}

Protocol_Throttle_Configure :: struct {
  using header : Protocol_Command_Header;
  packet_throttle_interval : u32;
  packet_throttle_acceleration : u32;
  packet_throttle_deceleration : u32;
}


Protocol :: union {
  header : Protocol_Command_Header;
  acknowledge : Protocol_Acknowledge;
  connect : Protocol_Connect;
  verify_connect : Protocol_Verify_Connect;
  disconnect : Protocol_Disconnect;
  ping : Protocol_Ping;
  send_reliable : Protocol_Send_Reliable;
  send_unreliable : Protocol_Send_Unreliable;
  send_unsequenced : Protocol_Send_Unsequenced;
  send_fragment : Protocol_Send_Fragment;
  bandwidth_limit : Protocol_Bandwidth_Limit;
  throttle_configure : Protocol_Throttle_Configure;
}

PROTOCOL_COMMAND_SIZES :: u32.[
  0,
  size_of(Protocol_Acknowledge),
  size_of(Protocol_Connect),
  size_of(Protocol_Verify_Connect),
  size_of(Protocol_Disconnect),
  size_of(Protocol_Ping),
  size_of(Protocol_Send_Reliable),
  size_of(Protocol_Send_Unreliable),
  size_of(Protocol_Send_Fragment),
  size_of(Protocol_Send_Unsequenced),
  size_of(Protocol_Bandwidth_Limit),
  size_of(Protocol_Throttle_Configure)
];

protocol_command_size :: (command : u32) -> u32 {
  return xx PROTOCOL_COMMAND_SIZES[command & PROTOCOL_COMMAND_MASK];
}

protocol_send_outgoing_commands :: (host: *Host, event: *Event, check_for_timeouts: bool) -> int {
  header_data : [size_of(Protocol_Header) + size_of(u32)]u8;
  header : *Protocol_Header = cast(*Protocol_Header)header_data.data;
  // :Time
  service_time := to_milliseconds(host.service_time);
  host.continue_sending = true;

  while host.continue_sending {
    for * peer: host.peers {
      if !host.continue_sending then break;
        if peer.state == .DISCONNECTED || peer.state == .ZOMBIE then continue;

        host.header_flags = 0;
        host.command_count = 0;
        host.buffer_count = 1;
        host.packet_size = size_of(Protocol_Header);

        if !list_empty(*peer.acknowledgements) {
          protocol_send_acknowledgements(host, peer);
        }

        if check_for_timeouts {
          if !list_empty(*peer.send_reliable_commands) && service_time >= peer.next_timeout {
            if protocol_check_timeouts(host, peer, event) == 1 {
              if event != null && event.type != .NONE { 
                return 1;
              } else {
                continue;
              }
            }
          }
        }

        if !list_empty(*peer.outgoing_reliable_commands) {
          if protocol_send_reliable_outgoing_commands(host, peer) {
            // :Time
            if list_empty(*peer.sent_reliable_commands) && service_time - peer.last_received_time >= peer.ping_interval {
              if peer.mtu - host.packet_size >= size_of(Protocol_Ping) {
                peer_ping(peer);
                protocol_send_reliable_outgoing_commands(host, peer);
              }
            }
          }
        }

        if !list_empty(*peer.outgoing_unreliable_commands) {
          protocol_send_unreliable_outgoing_commands(host, peer);
        }

        if host.command_count == 0 then continue;

        if peer.packet_loss_epoch == 0 { // :Time
          peer.packet_loss_epoch = service_time;
        } else if service_time - peer.packet_loss_epoch >= PEER_PACKET_LOSS_INTERVAL && peer.packets_sent > 0 {
          packet_loss := peer.packets_lost * PEER_PACKET_LOSS_SCALE / peer.packets_sent; 

          // @TODO optionally log packet loss here

          peer.packet_loss_variance -= peer.packet_loss_variance / 4;

          if packet_loss >= peer.packet_loss {
            peer.packet_loss += (packet_loss - peer.packet_loss) / 8;
            peer.packet_loss_variance += (packet_loss - peer.packet_loss) / 4;
          } else {
            peer.packet_loss -= (peer.packet_loss - packet_loss) / 8;
            peer.packet_loss_variance +=  (peer.packet_loss - packet_loss) / 4;
          }

          peer.packet_loss_epoch = service_time;
          peer.packets_sent = 0;
          peer.packets_lost = 0;
        }

        host.buffers[0].data = *header_data;
        if host.header_flags & PROTOCOL_FLAG_SENT_TIME {
          // :Time
          header.sent_time = host_to_net_endian(cast(u16)(service_time & 0xFFFF));
          host.buffers[0].length = size_of(Protocol_Header);
        } else {
          // offset_of sent_time
          host.buffers[0].length = size_of(u16);

        }

        // @TODO
        // if host.compressor.context != null && host.compressor.compress != null {
        //   log_error("TODO: Compression plugin is not implemented in peer_send_outgoing_commands\n");
        // }

        if peer.outgoing_peer_id < PROTOCOL_MAX_PEER_ID {
          host.header_flags |= peer.outgoing_session_id << PROTOCOL_SESSION_SHIFT;
        }

        header.peer_id = host_to_net_endian(cast(u16)(peer.outgoing_peer_id | host.header_flags));

        // @TODO
        // if host.checksum != null { }

        // @TODO
        // if should_compress { }

        peer.last_sent_time = service_time;
        sent_length := socket_send(host.socket, *peer.address, host.buffers, host.buffer_count);
        protocol_remove_sent_unreliable_commands(peer);

        if sent_length < 0 {
          host.buffers[0].data = null;
          return -1;
        }

        host.total_sent_data += xx sent_length;
        peer.total_data_sent += xx sent_length;
        host.total_sent_packets += 1;

    }
  }

  host.buffers[0].data = null;
  return 0;
}

protocol_receive_incoming_commands :: (host: *Host, event: *Event) -> int {

  for 0..255 {
    buffer : [1]Buffer;
    buffer[0].data = *host.packet_data[0];
    buffer[0].length = xx host.mtu;

    received_length := socket_receive(host.socket, *host.received_address, buffer, 1);

    if received_length == -2 continue;
    if received_length < 0 return -1;
    if received_length == 0 return 0;

    host.received_data = *host.packet_data[0];
    host.received_data_length = xx received_length;
    host.total_received_data_length += xx received_length;
    host.total_received_packets += 1;

    // @TODO
    // if host.intercept !== null { }

    if protocol_handle_incoming_commands(host, event) == {
      case 1; return 1;
      case -1; return -1;
      case; break;
    }
  }

  return -1;
}

protocol_dispatch_incoming_commands :: (host: *Host, event: *Event) -> int {
  while !list_empty(*host.dispatch_queue) {
    peer := cast(*Peer)list_remove(list_begin(*host.dispatch_queue));

    peer.needs_dispatch = false;

    if peer.state == {
      case .CONNECTION_PENDING; #through;
      case .CONNECTION_SUCCEEDED;
        protocol_change_state(host, peer, .CONNECTED);
        event.type = .CONNECT;
        event.peer = peer;
        event.data = peer.event_data;
        return 1;
      case .ZOMBIE;
        host.recalculate_bandwidth_limits = true;

        event.type = .DISCONNECT;
        event.peer = peer;
        event.data = peer.event_data;
      case .CONNECTED;
        if list_empty(*peer.dispatched_commands) continue;

        event.packet = peer_receive(peer, event.channel_id);
        if event.packet == null {
          continue;
        }

        event.type = .RECEIVE;
        event.peer = peer;

        if !list_empty(*peer.dispatched_commands) {
          peer.needs_dispatch = true;
        }

        list_insert(list_end(*host.dispatch_queue), *peer.dispatch_list);
        return 1;
      case;
        break;
    }
  }

  return 0;
}

protocol_send_acknowledgements :: (host: *Host, peer: *Peer) {
  log_error("TODO: protocol_send_acknowledgements is not implemented\n");
}

protocol_check_timeouts :: (host: *Host, peer: *Peer, event: *Event) -> int {
  log_error("TODO: protocol_check_timeouts is not implemented\n");
}

protocol_send_reliable_outgoing_commands :: (host: *Host, peer: *Peer) -> int {
  log_error("TODO: protocol_send_reliable_outgoing_commands is not implemented\n");
}

protocol_send_unreliable_outgoing_commands :: (host: *Host, peer: *Peer) -> int {
  log_error("TODO: protocol_send_unreliable_outgoing_commands is not implemented\n");
}

protocol_remove_sent_unreliable_commands :: (peer: *Peer) -> int {
  log_error("TODO: protocol_remove_sent_unreliable_commands is not implemented\n");
}

protocol_change_state :: (host: *Host, peer: *Peer, state: Peer_State) {
  if state == .CONNECTED || state == .DISCONNECT_LATER {
    peer_on_connect(peer);
  } else {
    peer_on_disconnect(peer);
  }

  peer.state = state;
}

protocol_handle_incoming_commands :: (host: *Host, event: *Event) -> int {
  log_error("TODO: protocol_handle_incoming_commands is not implemented\n");
}

