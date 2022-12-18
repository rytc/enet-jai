PROTOCOL_MAX_PEER_ID       :: 0xFFF;
PROTOCOL_MAX_CHANNEL_COUNT :: 255;
PROTOCOL_MAX_WINDOW_SIZE   :: 65536;
PROTOCOL_MIN_WINDOW_SIZE   :: 4096;
PROTOCOL_COMMAND_MASK          :u8: 0x0F;
PROTOCOL_FLAG_MASK             :u32: PROTOCOL_FLAG_COMPRESSED | PROTOCOL_FLAG_SENT_TIME;

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

protocol_send_outgoing_commands :: (host: *Host, event: *Event, check_for_timeout: bool) -> int {
  log_error("TODO: protocol_send_outgoing_commands is not implemented\n");
  return -1;
}

protocol_receive_incoming_commands :: (host: *Host, event: *Event) -> int {
  log_error("TODO: protocol_receive_incoming_commands is not implemented\n");
  return -1;
}

protocol_dispatch_incoming_commands :: (host: *Host, event: *Event) -> int {
  log_error("TODO: protocol_dispatch_incoming_commands is not implemented\n");
  return -1;

}



