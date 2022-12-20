Peer_State :: enum {
  DISCONNECTED;
  CONNECTING;
  ACKNOWLEDGING_CONNECT;
  CONNECTION_PENDING;
  CONNECTION_SUCCEEDED;
  CONNECTED;
  DISCONNECT_LATER;
  DISCONNECTING;
  ACKNOWLEDGING_DISCONNECT;
  ZOMBIE;
}

Peer :: struct {
  dispatch_list : List_Node;
  state : Peer_State;
  channels : [] Channel;
  address : Address;
  connect_id : u32;
  data : *void;
  mtu : u32;
  host : Host;
  window_size : u32;
  outgoing_peer_id : u16;
  incoming_peer_id : u16;
  outgoing_session_id : u8; 
  incoming_session_id : u8;
  outgoing_data_total : u32;
  incoming_data_total : u32;
  outgoing_bandwidth : u32;
  incoming_bandwidth : u32;
  outgoing_bandwidth_throttle_epoch : s64; // :Time
  incoming_bandwidth_throttle_epoch : s64; // :Time
  packet_throttle : u32;
  packet_throttle_limit : u32;
  packet_throttle_interval : u32;
  packet_throttle_acceleration : u32;
  packet_throttle_deceleration : u32;
  outgoing_reliable_seq_number : u16;
  outgoing_unsequenced_group : u16;
  outgoing_reliable_commands : List;
  outgoing_unreliable_commands : List;
  acknowledgements : List;
  send_reliable_commands : List;
  sent_reliable_commands : List;
  next_timeout : s64; // :Time
  last_received_time : s64; // :Time
  last_sent_time : s64; // :Time
  ping_interval : s64; // :Time
  packet_loss_epoch : s64; // :Time
  packets_sent : u32;
  packets_lost : u32;
  packet_loss : u32;
  packet_loss_variance : u32;
  total_data_sent : u64;
  needs_dispatch : bool;
  dispatched_commands : List;
  event_data : u32;
}

#scope_module

PEER_WINDOW_SIZE_SCALE      :: 64 * 1024;
PEER_RELIABLE_WINDOWS       :u16: 16;
PEER_PACKET_THROTTLE_SCALE  :: 32;
PEER_PACKET_LOSS_INTERVAL   :: 10000;
PEER_PACKET_LOSS_SCALE      :: (1 << 16);

peer_queue_outgoing_command :: (peer: *Peer, command: *Protocol, packet: *Packet, offset: u32, length: u16) -> *Outgoing_Command {
  outgoing_cmd := New(Outgoing_Command);

  outgoing_cmd.command = <<command;
  outgoing_cmd.fragment_offset = offset;
  outgoing_cmd.fragment_length = length;
  outgoing_cmd.packet = packet;

  if packet packet.ref_count += 1;

  peer_setup_outgoing_command(peer, outgoing_cmd);

  return outgoing_cmd;
}

peer_setup_outgoing_command :: (peer: *Peer, outgoing_cmd: *Outgoing_Command) {
  channel : Channel;
  peer.outgoing_data_total += protocol_command_size(outgoing_cmd.command.header.command) + outgoing_cmd.fragment_length;

  if outgoing_cmd.command.header.channel_id == 0xFF {
    peer.outgoing_reliable_seq_number += 1;
    outgoing_cmd.reliable_seq_number = peer.outgoing_reliable_seq_number;
    outgoing_cmd.unreliable_seq_number = 0;
  } else if outgoing_cmd.command.header.command & PROTOCOL_FLAG_ACKNOWLEDGE {
    peer.outgoing_reliable_seq_number += 1;
    channel = *peer.channels[outgoing_cmd.command.header.channel_id];
    outgoing_cmd.reliable_seq_number = channel.outgoing_reliable_seq_number;
    outgoing_cmd.unreliable_seq_number = 0;
  } else if outgoing_cmd.command.header.command & PROTOCOL_FLAG_UNSEQUENCED {
    peer.outgoing_unsequenced_group += 1;
    outgoing_cmd.reliable_seq_number = 0;
    outgoing_cmd.unreliable_seq_number = 0;
  } else {
    if outgoing_cmd.fragment_offset == 0 channel.outgoing_unreliable_seq_number += 1;

    channel = *peer.channels[outgoing_cmd.command.header.channel_id];
    
    outgoing_cmd.reliable_seq_number = channel.outgoing_reliable_seq_number;
    outgoing_cmd.unreliable_seq_number = channel.outgoing_unreliable_seq_number;
  }

  outgoing_cmd.send_attempts = 0;
  outgoing_cmd.send_time = 0;
  outgoing_cmd.round_trip_timeout = 0;
  outgoing_cmd.round_trip_timeout_limit = 0;
  outgoing_cmd.command.header.reliable_seq_number = host_to_net_endian(outgoing_cmd.reliable_seq_number);


  if outgoing_cmd.command.header.command & PROTOCOL_COMMAND_MASK == {
    case PROTOCOL_COMMAND_SEND_UNRELIABLE;
      outgoing_cmd.command.send_unreliable.unreliable_seq_number = host_to_net_endian(outgoing_cmd.unreliable_seq_number);
    case PROTOCOL_COMMAND_SEND_UNSEQUENCED;
      outgoing_cmd.command.send_unsequenced.unsequenced_group = host_to_net_endian(peer.outgoing_unsequenced_group);
  }    

  if outgoing_cmd.command.header.command & PROTOCOL_FLAG_ACKNOWLEDGE {
    list_insert(list_end(*peer.outgoing_reliable_commands), outgoing_cmd);
  } else {
    list_insert(list_end(*peer.outgoing_unreliable_commands), outgoing_cmd);
  }
}

peer_ping :: (peer: *Peer) {
  log_error("TODO peer_ping not implemented\n");
}

peer_on_connect :: (peer: *Peer) {
  if peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER {
    if peer.incoming_bandwidth != 0 {
      peer.host.bandwidth_limited_peers += 1;
    }

    peer.host.connected_peers += 1;
  }
}

peer_on_disconnect :: (peer: *Peer) {
  if peer.state == .CONNECTED && peer.state == .DISCONNECT_LATER {
    if peer.incoming_bandwidth != 0 {
      peer.host.bandwidth_limited_peers -= 1;
    }

    peer.host.connected_peers -= 1;
  }

}

peer_receive :: (peer: *Peer, channel_id: u16) -> *Packet {
  log_error("TODO: peer_receive not implemented\n");
}

