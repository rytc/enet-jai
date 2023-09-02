PROTOCOL_MAX_PEER_ID         :: 0xFFF;
PROTOCOL_MAX_CHANNEL_COUNT   :: 255;
PROTOCOL_MIN_CHANNEL_COUNT   :: 1;
PROTOCOL_MAX_WINDOW_SIZE     :: 65536;
PROTOCOL_MIN_WINDOW_SIZE     :: 4096;
PROTOCOL_MAX_PACKET_COMMANDS :: 32;
PROTOCOL_MAX_MTU             :: 4096;
PROTOCOL_MIN_MTU             :: 576;
PROTOCOL_SESSION_SHIFT       :: 12;
PROTOCOL_SESSION_MASK        :: 3 << 12;
PROTOCOL_MAX_FRAGMENT_COUNT  :: 1024 * 1024;

PROTOCOL_FLAG_COMPRESSED  :u32: 1 << 14;
PROTOCOL_FLAG_SENT_TIME   :u32: 1 << 15;
PROTOCOL_FLAG_MASK        :u32: PROTOCOL_FLAG_COMPRESSED | PROTOCOL_FLAG_SENT_TIME;
PROTOCOL_COMMAND_COUNT                    :: 13;

Protocol_Command :: enum u8 {
    NONE                     :: 0;
    ACKNOWLEDGE              :: 1;
    CONNECT                  :: 2;
    VERIFY_CONNECT           :: 3;
    DISCONNECT               :: 4;
    PING                     :: 5;
    SEND_RELIABLE            :: 6;
    SEND_UNRELIABLE          :: 7;
    SEND_FRAGMENT            :: 8;
    SEND_UNSEQUENCED         :: 9;
    BANDWIDTH_LIMIT          :: 10;
    THROTTLE_CONFIGURE       :: 11;
    SEND_UNRELIABLE_FRAGMENT :: 12;

    MASK :: 0x0F;

    FLAG_ACKNOWLEDGE :: 1 << 7;
    FLAG_UNSEQUENCED :: 1 << 6;

    SEND_RELIABLE_UNSEQUENCED :: SEND_RELIABLE | FLAG_UNSEQUENCED;
    SEND_FRAGMENT_ACKNOWLEDGE :: SEND_FRAGMENT | FLAG_ACKNOWLEDGE;
    SEND_RELIABLE_ACKNOWLEDGE :: SEND_RELIABLE | FLAG_ACKNOWLEDGE;
}

Protocol_Header :: struct {
    peer_id   : u16;
    sent_time : u16;
}

Protocol_Command_Header :: struct {
    command             : Protocol_Command;
    channel_id          : u8;
    reliable_seq_number : u16;
}

Protocol_Acknowledge :: struct {
    using header : Protocol_Command_Header;

    received_reliable_seq_number : u16;
    received_sent_time           : u16;
}

Protocol_Connect :: struct {
    using header : Protocol_Command_Header;

    outgoing_peer_id    : u16;
    incoming_session_id : u8;
    outgoing_session_id : u8;
    
    mtu           : u32;
    window_size   : u32;
    channel_count : u32;

    incoming_bandwidth : u32;
    outgoing_bandwidth : u32;

    packet_throttle_interval     : u32;
    packet_throttle_acceleration : u32;
    packet_throttle_deceleration : u32;
    
    connect_id : u32;
    data       : u32;
}

Protocol_Verify_Connect :: struct {
    using header : Protocol_Command_Header;

    outgoing_peer_id    : u16;
    incoming_session_id : u8;
    outgoing_session_id : u8;

    mtu           : u32;
    window_size   : u32;
    channel_count : u32;

    incoming_bandwidth : u32;
    outgoing_bandwidth : u32;

    packet_throttle_interval     : u32;
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
    data_length  : u16;
}

Protocol_Send_Unreliable :: struct {
    using header : Protocol_Command_Header;

    unreliable_seq_number : u16;
    data_length           : u16;
}

Protocol_Send_Fragment :: struct {
    using header : Protocol_Command_Header;

    start_seq_number : u16;
    data_length      : u16;
    fragment_count   : u32;
    fragment_number  : u32;
    total_length     : u32;
    fragment_offset  : u32;
}

Protocol_Send_Unsequenced :: struct {
    using header : Protocol_Command_Header;

    unsequenced_group : u16;
    data_length       : u16;
}

Protocol_Bandwidth_Limit :: struct {
    using header : Protocol_Command_Header;

    incoming_bandwidth : u32;
    outgoing_bandwidth : u32;
}

Protocol_Throttle_Configure :: struct {
    using header : Protocol_Command_Header;

    packet_throttle_interval     : u32;
    packet_throttle_acceleration : u32;
    packet_throttle_deceleration : u32;
}


Protocol :: union {
    header             : Protocol_Command_Header;
    acknowledge        : Protocol_Acknowledge;
    connect            : Protocol_Connect;
    verify_connect     : Protocol_Verify_Connect;
    disconnect         : Protocol_Disconnect;
    ping               : Protocol_Ping;
    send_reliable      : Protocol_Send_Reliable;
    send_unreliable    : Protocol_Send_Unreliable;
    send_unsequenced   : Protocol_Send_Unsequenced;
    send_fragment      : Protocol_Send_Fragment;
    bandwidth_limit    : Protocol_Bandwidth_Limit;
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
    size_of(Protocol_Throttle_Configure),
    size_of(Protocol_Send_Fragment)
];

protocol_command_size :: (command : Protocol_Command) -> u32 {
    return xx PROTOCOL_COMMAND_SIZES[cast(u32)(command & .MASK)];
}

protocol_send_outgoing_commands :: (host: *Host, event: *Event, check_for_timeouts: bool) -> Result_Status {
    header_data : [size_of(Protocol_Header) + size_of(u32)]u8;
    header : *Protocol_Header = cast(*Protocol_Header)header_data.data;
    host.continue_sending = true;

    while host.continue_sending {
        for * peer: host.peers {
            host.continue_sending = false;
            if peer.state == .DISCONNECTED || peer.state == .ZOMBIE then continue;

            host.header_flags = 0;
            host.command_count = 0;
            host.buffer_count = 1;
            host.packet_size = size_of(Protocol_Header);

            if !list_empty(*peer.acknowledgements) {
                protocol_send_acknowledgements(host, peer);
            }

            if check_for_timeouts &&
                !list_empty(*peer.sent_reliable_commands) && 
                host.service_time >= peer.next_timeout &&
                protocol_check_timeouts(host, peer, event) == true {

                if event != null && event.type != .NONE { 
                    return .FAILURE;
                } else {
                    continue;
                }
            }

            if (list_empty(*peer.outgoing_reliable_commands) || 
                protocol_send_reliable_outgoing_commands(host, peer)) &&
                list_empty(*peer.sent_reliable_commands) && 
                host.service_time - peer.last_received_time >= peer.ping_interval &&
                peer.mtu - host.packet_size >= size_of(Protocol_Ping) 
             {

                peer_ping(peer);
                protocol_send_reliable_outgoing_commands(host, peer);
            }

            if !list_empty(*peer.outgoing_unreliable_commands) {
                protocol_send_unreliable_outgoing_commands(host, peer);
            }

            if host.command_count == 0 then continue;

            if peer.packet_loss_epoch == 0 { // :Time
                peer.packet_loss_epoch = host.service_time;
            } else if host.service_time - peer.packet_loss_epoch >= PEER_PACKET_LOSS_INTERVAL && peer.packets_sent > 0 {
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

                peer.packet_loss_epoch = host.service_time;
                peer.packets_sent = 0;
                peer.packets_lost = 0;
            }

            host.buffers[0].data = *header_data;
            if host.header_flags & PROTOCOL_FLAG_SENT_TIME {
                // :Time
                header.sent_time = host_to_net_endian(cast(u16)(host.service_time & 0xFFFF));
                host.buffers[0].length = size_of(Protocol_Header);
            } else {
                // offset_of sent_time Protocol_Header
                host.buffers[0].length = size_of(u16);

            }

            // @TODO :compression
            // if host.compressor.context != null && host.compressor.compress != null 

            if peer.outgoing_peer_id < PROTOCOL_MAX_PEER_ID {
                host.header_flags |= peer.outgoing_session_id << PROTOCOL_SESSION_SHIFT;
            }

            header.peer_id = host_to_net_endian(cast(u16)(peer.outgoing_peer_id | host.header_flags));

            // @TODO :checksum
            // if host.checksum != null { }

            // @TODO :compression
            // if should_compress { }

            peer.last_sent_time = host.service_time;

            sent_length := socket_send(host.socket, *peer.address, host.buffers, host.buffer_count);
            // print("Sent packet of size %\n", sent_length);
            protocol_remove_sent_unreliable_commands(peer);

            if sent_length < 0 {
                host.buffers[0].data = null;
                return .ERROR;
            }

            host.total_sent_data += xx sent_length;
            peer.total_data_sent += xx sent_length;
            host.total_sent_packets += 1;

            if !host.continue_sending then break;
        }
    }

    host.buffers[0].data = null;
    return .NONE;
}

protocol_receive_incoming_commands :: (host: *Host, event: *Event) -> Result_Status {

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

        // print("received packet of size %\n", received_length);

        // @TODO
        // if host.intercept !== null { }

        if protocol_handle_incoming_commands(host, event) == {
            case .SUCCESS; return .SUCCESS;
            case .ERROR; return .ERROR;
        }
    }

    return .ERROR;
}

protocol_dispatch_incoming_commands :: (host: *Host, event: *Event) -> Result_Status {
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
                return .SUCCESS;
            case .ZOMBIE;
                host.recalculate_bandwidth_limits = true;

                event.type = .DISCONNECT;
                event.peer = peer;
                event.data = peer.event_data;

                peer_reset(peer);

                return .SUCCESS;
            case .CONNECTED;
                if list_empty(*peer.dispatched_commands) continue;

                event.packet = peer_receive(peer, *event.channel_id);
                if event.packet == null {
                    continue;
                }

                event.type = .RECEIVE;
                event.peer = peer;

                if !list_empty(*peer.dispatched_commands) {
                    peer.needs_dispatch = true;
                }

                list_insert(list_end(*host.dispatch_queue), *peer.dispatch_list);
                return .SUCCESS;
        }
    }

    return .NONE;
}

protocol_send_acknowledgements :: (host: *Host, peer: *Peer) {
    command := *host.commands[host.command_count];
    buffer := *host.buffers[host.buffer_count];

    current_ack := list_begin(*peer.acknowledgements); 

    while current_ack != list_end(*peer.acknowledgements) {
        // @TODO :fix_loop_check
        if command - host.commands.data >= PROTOCOL_MAX_PACKET_COMMANDS ||
            buffer - host.buffers.data + 1 >= MAX_BUFFER_COUNT ||
            peer.mtu - host.packet_size < size_of(Protocol_Acknowledge) {

            host.continue_sending = true;
            break;
        }

        ack := cast(*Acknowledgement)current_ack;
        current_ack = cast(*Acknowledgement)list_next(current_ack);

        buffer.data = command;
        buffer.length = size_of(Protocol_Acknowledge);
        host.packet_size += xx buffer.length;

        reliable_seq_number := host_to_net_endian(ack.command.header.reliable_seq_number);

        command.header.command = Protocol_Command.ACKNOWLEDGE;
        command.header.channel_id = ack.command.header.channel_id;
        command.header.reliable_seq_number = reliable_seq_number;
        command.acknowledge.received_reliable_seq_number = reliable_seq_number;
        command.acknowledge.received_sent_time = host_to_net_endian(cast(u16)ack.sent_time);

        if ack.command.header.command & .MASK == .DISCONNECT then protocol_dispatch_state(host, peer, .ZOMBIE);

        list_remove(ack);
        free(ack);

        command += 1;
        buffer += 1;
    }

    host.command_count = cast(u32)(command - host.commands.data); 
    host.buffer_count = cast(u32)(buffer - host.buffers.data);
}

// Returns true if the peer timed out
protocol_check_timeouts :: (host: *Host, peer: *Peer, event: *Event) -> bool {

    insert_pos := list_begin(*peer.outgoing_reliable_commands);
    current_cmd := list_begin(*peer.sent_reliable_commands);

    while current_cmd != list_end(*peer.sent_reliable_commands) {
        outgoing_cmd := cast(*Outgoing_Command)current_cmd;
        current_cmd = list_next(current_cmd);

        // :Time
        if host.service_time - outgoing_cmd.sent_time < outgoing_cmd.round_trip_timeout {
            continue;
        }

        // :Time
        if peer.earliest_timeout == 0 || outgoing_cmd.sent_time < peer.earliest_timeout {
            peer.earliest_timeout = outgoing_cmd.sent_time;
        }

        // :Time
        if peer.earliest_timeout != 0 && (
            host.service_time - peer.earliest_timeout >= peer.timeout_maximum ||
            (outgoing_cmd.round_trip_timeout >= outgoing_cmd.round_trip_timeout_limit &&
            host.service_time - peer.earliest_timeout >= peer.timeout_minimum)) {

            protocol_notify_disconnect_timeout(host, peer, event);
            return true;
        }

        if outgoing_cmd.packet != null {
            peer.reliable_data_in_transit -= outgoing_cmd.fragment_length;
        }

        peer.packets_lost += 1;
        peer.total_packets_lost += 1;

        outgoing_cmd.round_trip_timeout = peer.round_trip_timeout + 4 * peer.round_trip_time_variance;
        outgoing_cmd.round_trip_timeout_limit = peer.timeout_limit * outgoing_cmd.round_trip_timeout;

        list_insert(insert_pos, list_remove(outgoing_cmd));

        if current_cmd == list_begin(*peer.sent_reliable_commands) && !list_empty(*peer.sent_reliable_commands) {
            outgoing_cmd = cast(*Outgoing_Command)current_cmd;
            peer.next_timeout = outgoing_cmd.sent_time + outgoing_cmd.round_trip_timeout;
        }
    }

    return false;
}

protocol_send_reliable_outgoing_commands :: (host: *Host, peer: *Peer) -> bool {
    cmd := *host.commands[host.command_count];
    buffer := *host.buffers[host.buffer_count];

    window_wrap := false;
    window_exceeded := false;
    can_ping := true;

    current_cmd := list_begin(*peer.outgoing_reliable_commands);

    while current_cmd != list_end(*peer.outgoing_reliable_commands) {
        outgoing_cmd := cast(*Outgoing_Command)current_cmd;

        channel := ifx outgoing_cmd.command.header.channel_id < peer.channels.count then *peer.channels[outgoing_cmd.command.header.channel_id] else cast(*Channel)null;
        reliable_window := outgoing_cmd.reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;

        if channel != null {
            if !window_wrap && outgoing_cmd.send_attempts < 1 &&
                !(outgoing_cmd.reliable_seq_number % PEER_RELIABLE_WINDOW_SIZE) && 
                (channel.reliable_windows[(reliable_window + PEER_RELIABLE_WINDOWS - 1)
                % PEER_RELIABLE_WINDOWS] >= PEER_RELIABLE_WINDOW_SIZE ||
                channel.used_reliable_windows & ((((1 << PEER_FREE_RELIABLE_WINDOWS) - 1) << reliable_window)
                | (((1 << PEER_FREE_RELIABLE_WINDOWS) - 1) >> (PEER_RELIABLE_WINDOWS - reliable_window)))) {

                window_wrap = true;
            }

            if window_wrap {
                current_cmd = list_next(current_cmd);
                continue;
            }
        }

        if outgoing_cmd.packet != null {
            if !window_exceeded {
                window_size := (peer.packet_throttle * peer.window_size) / PEER_PACKET_THROTTLE_SCALE;

                if peer.reliable_data_in_transit + outgoing_cmd.fragment_length > max(window_size, peer.mtu) then window_exceeded = true;
            }

            if window_exceeded {
                current_cmd = list_next(current_cmd);
                continue;
            }
        }

        can_ping = false;
        cmd_size := protocol_command_size(outgoing_cmd.command.header.command);

        if cmd - host.commands.data >= PROTOCOL_MAX_PACKET_COMMANDS ||
            buffer - host.buffers.data + 1 >= cast(u32)(MAX_BUFFER_COUNT) ||
            peer.mtu - host.packet_size < cmd_size ||
            (outgoing_cmd.packet != null && cast(u16)(peer.mtu - host.packet_size) < cast(u16)(cmd_size + outgoing_cmd.fragment_length)) {

            host.continue_sending = true;
            break;
        }

        if channel && outgoing_cmd.send_attempts < 1 {
            channel.used_reliable_windows |= cast(u16)1 << reliable_window;
            channel.reliable_windows[reliable_window] += 1;
        }

        outgoing_cmd.send_attempts += 1;

        if outgoing_cmd.round_trip_timeout == 0 {
            outgoing_cmd.round_trip_timeout = peer.round_trip_time + 4 * peer.round_trip_time_variance;
            outgoing_cmd.round_trip_timeout_limit = peer.timeout_limit * outgoing_cmd.round_trip_timeout;
        }

        // :Time
        if list_empty(*peer.sent_reliable_commands) then peer.next_timeout = host.service_time + outgoing_cmd.round_trip_timeout;

        current_cmd = list_next(current_cmd);
        list_insert(list_end(*peer.sent_reliable_commands), list_remove(outgoing_cmd));

        outgoing_cmd.sent_time = cast(u32)host.service_time;

        buffer.data = cmd;
        buffer.length = cmd_size;

        host.packet_size += cast(u32)buffer.length;
        host.header_flags |= PROTOCOL_FLAG_SENT_TIME;

        <<cmd = outgoing_cmd.command;

        if outgoing_cmd.packet {
            buffer += 1;
            buffer.data = outgoing_cmd.packet.data + outgoing_cmd.fragment_offset;
            buffer.length = outgoing_cmd.fragment_length;
            host.packet_size += outgoing_cmd.fragment_length;
            peer.reliable_data_in_transit += outgoing_cmd.fragment_length;
        }

        peer.packets_sent += 1;
        peer.total_packets_sent += 1;

        cmd += 1;
        buffer += 1;
    }

    host.command_count = cast(u32)(cmd - host.commands.data);
    host.buffer_count = cast(u32)(buffer - host.buffers.data);

    return can_ping;
}

// @TODO this has no_abc because host.buffer_count may be larger than the number
// of buffers. Should check the host.buffer_count before attempting to access the array.
// The reason it's done this way is because the code after the loop needs to run either way
protocol_send_unreliable_outgoing_commands :: (host: *Host, peer: *Peer) #no_abc {
    command := *host.commands[host.command_count];
    buffer := *host.buffers[host.buffer_count];

    current_cmd := list_begin(*peer.outgoing_unreliable_commands);
    while current_cmd != list_end(*peer.outgoing_unreliable_commands) {
        outgoing_cmd := cast(*Outgoing_Command)current_cmd;
        cmd_size := protocol_command_size(outgoing_cmd.command.header.command);

        if command - host.commands.data >= PROTOCOL_MAX_PACKET_COMMANDS ||
            buffer + 1 - host.buffers.data >= MAX_BUFFER_COUNT ||
            peer.mtu - host.packet_size < size_of(Protocol_Acknowledge) ||
            (outgoing_cmd.packet != null && peer.mtu - host.packet_size < cmd_size + outgoing_cmd.fragment_length) {

            host.continue_sending = true;
            break;
        }

        current_cmd = list_next(current_cmd);

        if outgoing_cmd.packet != null && outgoing_cmd.fragment_offset == 0 {
            peer.packet_throttle_counter += PEER_PACKET_THROTTLE_COUNTER;
            peer.packet_throttle_counter %= PEER_PACKET_THROTTLE_SCALE;

            if peer.packet_throttle_counter > peer.packet_throttle {
                reliable_seq_number := outgoing_cmd.reliable_seq_number;
                unreliable_seq_number := outgoing_cmd.unreliable_seq_number;

                while true {
                    outgoing_cmd.packet.ref_count -= 1;

                    if outgoing_cmd.packet.ref_count == 0 packet_destroy(outgoing_cmd.packet);

                    list_remove(outgoing_cmd);
                    free(outgoing_cmd);

                    if current_cmd == list_end(*peer.outgoing_unreliable_commands) then break;

                    outgoing_cmd = cast(*Outgoing_Command)current_cmd;

                    if outgoing_cmd.reliable_seq_number != reliable_seq_number || outgoing_cmd.unreliable_seq_number != unreliable_seq_number then break;

                    current_cmd = list_next(current_cmd);
                }

                continue;
            }
        }

        buffer.data = command;
        buffer.length = cmd_size;
        host.packet_size += buffer.length;
        <<command = outgoing_cmd.command;
        list_remove(outgoing_cmd);

        if outgoing_cmd.packet != null {
            buffer += 1;
            buffer.data = outgoing_cmd.packet.data + outgoing_cmd.fragment_offset;
            buffer.length = outgoing_cmd.fragment_length;
            host.packet_size += buffer.length;
            list_insert(list_end(*peer.sent_unreliable_commands), outgoing_cmd);
        } else {
            free(outgoing_cmd);
        }

        command += 1;
        buffer += 1;
    }

    host.command_count = cast(u32)(command - host.commands.data);
    host.buffer_count = cast(u32)(buffer - host.buffers.data);

    if peer.state == .DISCONNECT_LATER &&
        list_empty(*peer.outgoing_reliable_commands) &&
        list_empty(*peer.outgoing_unreliable_commands) &&
        list_empty(*peer.sent_reliable_commands) {

        peer_disconnect(peer, peer.event_data);
    }
}

protocol_remove_sent_unreliable_commands :: (peer: *Peer) {
    while !list_empty(*peer.sent_unreliable_commands) {
        outgoing_cmd := cast(*Outgoing_Command)list_front(*peer.sent_unreliable_commands);
        list_remove(outgoing_cmd);

        if outgoing_cmd.packet != null {
            outgoing_cmd.packet.ref_count -= 1;

            if outgoing_cmd.packet.ref_count == 0 {
                outgoing_cmd.packet.flags |= .SENT;
                packet_destroy(outgoing_cmd.packet);
            }
        }

        free(outgoing_cmd);
    }
}

protocol_change_state :: (host: *Host, peer: *Peer, state: Peer_State) {
    if state == .CONNECTED || state == .DISCONNECT_LATER {
        peer_on_connect(peer);
    } else {
        peer_on_disconnect(peer);
    }

    peer.state = state;
}

protocol_dispatch_state :: (host: *Host, peer: *Peer, state: Peer_State) {
    protocol_change_state(host, peer, state);

    if !peer.needs_dispatch {
        list_insert(list_end(*host.dispatch_queue), *peer.dispatch_list);
        peer.needs_dispatch = true;
    }
}

protocol_handle_verify_connect :: (host: *Host, event: *Event, peer: *Peer, command: Protocol) -> Result_Status {
    if peer.state != .CONNECTING then return .NONE;

    channel_count := net_to_host_endian(command.verify_connect.channel_count);

    // @TODO :giant_if
    if channel_count < PROTOCOL_MIN_CHANNEL_COUNT || channel_count > PROTOCOL_MAX_CHANNEL_COUNT ||
        net_to_host_endian(command.verify_connect.packet_throttle_interval) != peer.packet_throttle_interval ||
        net_to_host_endian(command.verify_connect.packet_throttle_acceleration) != peer.packet_throttle_acceleration ||
        net_to_host_endian(command.verify_connect.packet_throttle_deceleration) != peer.packet_throttle_deceleration ||
        command.verify_connect.connect_id != peer.connect_id {
        
        peer.event_data = 0;
        protocol_dispatch_state(host, peer, .ZOMBIE);
        return .ERROR;
    }

    protocol_remove_sent_reliable_command(peer, 1, 0xFF);

    if channel_count < peer.channels.count {
        array_free(peer.channels);
        peer.channels = NewArray(channel_count, Channel);

        for * channel: peer.channels channel_reset(channel);
    }

    peer.outgoing_peer_id = net_to_host_endian(command.verify_connect.outgoing_peer_id);
    peer.incoming_session_id = command.verify_connect.incoming_session_id;
    peer.outgoing_session_id = command.verify_connect.outgoing_session_id;

    mtu := net_to_host_endian(command.verify_connect.mtu);

    if mtu < PROTOCOL_MIN_MTU then mtu = PROTOCOL_MIN_MTU;
    else if mtu > PROTOCOL_MAX_MTU then mtu = PROTOCOL_MAX_MTU;

    if mtu < peer.mtu then peer.mtu = mtu;
    
    window_size := net_to_host_endian(command.verify_connect.window_size);
    if window_size < PROTOCOL_MIN_WINDOW_SIZE then window_size = PROTOCOL_MIN_WINDOW_SIZE;
    else if window_size > PROTOCOL_MAX_WINDOW_SIZE then window_size = PROTOCOL_MAX_WINDOW_SIZE;

    if window_size < peer.window_size then peer.window_size = window_size;

    peer.incoming_bandwidth = net_to_host_endian(command.verify_connect.incoming_bandwidth);
    peer.outgoing_bandwidth = net_to_host_endian(command.verify_connect.outgoing_bandwidth);

    protocol_notify_connect(host, peer, event);
    return .NONE;
}

protocol_remove_sent_reliable_command :: (peer: *Peer, reliable_seq_number: u16, channel_id: u8) -> Protocol_Command {
    outgoing_cmd : *Outgoing_Command;
    was_sent := true;

    for peer.sent_reliable_commands {
        outgoing_cmd = cast(*Outgoing_Command)it;
        if outgoing_cmd.reliable_seq_number == reliable_seq_number && outgoing_cmd.command.header.channel_id == channel_id then break;
    }

    if outgoing_cmd == cast(*Outgoing_Command)list_end(*peer.sent_reliable_commands) {
        for *peer.outgoing_reliable_commands {
            outgoing_cmd = cast(*Outgoing_Command)it;

            if outgoing_cmd.send_attempts < 1 then return .NONE;
            if outgoing_cmd.reliable_seq_number == reliable_seq_number && outgoing_cmd.command.header.channel_id == channel_id then break;
        }

        if outgoing_cmd == cast(*Outgoing_Command)list_end(*peer.outgoing_reliable_commands) then return .NONE;
        was_sent = false;
    }

    if outgoing_cmd == null then return .NONE;

    if channel_id < peer.channels.count {
        channel := *peer.channels[channel_id];
        reliable_window := reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;
        if channel.reliable_windows[reliable_window] > 0 {
            channel.reliable_windows[reliable_window] -= 1;
            if !channel.reliable_windows[reliable_window] then channel.used_reliable_windows &= ~(cast(u16)1 << reliable_window);
        }
    }

    cmd_number := outgoing_cmd.command.header.command & .MASK;
    list_remove(outgoing_cmd);

    if outgoing_cmd.packet != null {
        if was_sent then peer.reliable_data_in_transit -= outgoing_cmd.fragment_length;

        outgoing_cmd.packet.ref_count -= 1;

        if outgoing_cmd.packet.ref_count == 0 {
            outgoing_cmd.packet.flags |= Packet_Flags.SENT;
            packet_destroy(outgoing_cmd.packet);
        }
    }

    free(outgoing_cmd);

    if list_empty(*peer.sent_reliable_commands) return cmd_number;

    outgoing_cmd = cast(*Outgoing_Command)list_front(*peer.sent_reliable_commands);

    peer.next_timeout = outgoing_cmd.sent_time + outgoing_cmd.round_trip_timeout;

    return cmd_number;
}

protocol_handle_incoming_commands :: (host: *Host, event: *Event) -> Result_Status {
    // offset_of sent_time of Protocol_Header
    if host.received_data_length < size_of(u16) return .NONE;

    header := cast(*Protocol_Header)host.received_data;

    peer_id :u16= net_to_host_endian(header.peer_id);
    session_id := (peer_id & PROTOCOL_SESSION_MASK) >> PROTOCOL_SESSION_SHIFT;
    flags := peer_id & PROTOCOL_FLAG_MASK;
    peer_id &= ~(cast(u16)PROTOCOL_FLAG_MASK | cast(u16)PROTOCOL_SESSION_MASK);

    // size_of(u16) = offset_of sent_time from Protocol_Header
    header_size := ifx flags & PROTOCOL_FLAG_SENT_TIME then size_of(Protocol_Header) else size_of(u16);

    // @TODO :checksum support
    // if host.checksum != null header_size += size_of(u32);

    peer: *Peer;
    if peer_id == PROTOCOL_MAX_PEER_ID {
        peer = null;
    } else if peer_id >= host.peers.count {
        return .ERROR;
    } else {
        peer = *host.peers[peer_id];

        is_address_equal := in6_equal(host.received_address.host, peer.address.host);
        is_port_equal := host.received_address.port == peer.address.port;

        if peer.state == .DISCONNECTED || peer.state == .ZOMBIE ||
            ((!is_address_equal || !is_port_equal)) ||
            (peer.outgoing_peer_id < PROTOCOL_MAX_PEER_ID && session_id != peer.incoming_session_id) {

            return .NONE;
        }
    }

    // @TODO :compression support
    // if flags & PROTOCOL_FLAG_COMPRESSED {
    //     log_error("enet: compression is not yet supported\n");
    // }

    // @TODO :checksum support
    // if host.checksum != null { }

    if peer {
        peer.address.host = host.received_address.host;
        peer.address.port = host.received_address.port;
        peer.incoming_data_total += host.received_data_length;
        peer.total_data_received +=  host.received_data_length;
    }

    current_data := host.received_data + header_size;

    while current_data < host.received_data + host.received_data_length {

        command := cast(*Protocol)current_data;

        if current_data + size_of(Protocol_Command_Header)  > host.received_data + host.received_data_length {
            break;
        }

        command_number := command.header.command & .MASK;
        if command_number > PROTOCOL_COMMAND_COUNT break;

        command_size := protocol_command_size(command_number);

        if command_size == 0 || current_data + command_size > host.received_data + host.received_data_length break;

        current_data += command_size;

        if peer == null && (command_number != .CONNECT || current_data < host.received_data + host.received_data_length) break;

        command.header.reliable_seq_number = net_to_host_endian(command.header.reliable_seq_number);

        // print("Incoming command (from peer %)%\n", peer_id, cast(Protocol_Command)command_number);

        if command_number == {
            case .ACKNOWLEDGE; protocol_handle_acknowledge(host, event, peer, command);
            case .CONNECT; 
                if peer != null  continue;
                peer = protocol_handle_connect(host, header, command);
                if peer == null break;
            case .VERIFY_CONNECT;   protocol_handle_verify_connect(host, event, peer, command);
            case .DISCONNECT;       protocol_handle_disconnect(host, peer, command);
            case .PING;             protocol_handle_ping(host, peer, command);
            case .SEND_RELIABLE;    protocol_handle_send_reliable(host, peer, command, *current_data);
            case .SEND_UNRELIABLE;  protocol_handle_send_unreliable(host, peer, command, *current_data);
            case .SEND_UNSEQUENCED; protocol_handle_send_unsequenced(host, peer, command, *current_data); 
            case .SEND_FRAGMENT;    protocol_handle_send_fragment(host, peer, command, *current_data);
            case .BANDWIDTH_LIMIT;  protocol_handle_bandwidth_limit(host, peer, command);
            case .THROTTLE_CONFIGURE; protocol_handle_throttle_configure(host, peer, command);
            case .SEND_UNRELIABLE_FRAGMENT; protocol_handle_send_unreliable_fragment(host, peer, command, *current_data);
            case; break;
        }

        assert(peer != null);
        if command.header.command & .FLAG_ACKNOWLEDGE != 0 {
            if !(flags & PROTOCOL_FLAG_SENT_TIME) break;

            sent_time := net_to_host_endian(header.sent_time);

            if peer.state == {
                case .DISCONNECTING; #through;
                case .ACKNOWLEDGING_CONNECT; #through;
                case .DISCONNECTED; #through;
                case .ZOMBIE; // do nothing 
                case .ACKNOWLEDGING_DISCONNECT;
                    if command.header.command & .MASK == .DISCONNECT peer_queue_acknowledgement(peer, command, sent_time);
                case;
                    peer_queue_acknowledgement(peer, command, sent_time);
            }
        }
    }

    if event != null && event.type != .NONE return .SUCCESS;

    return .NONE;
}

protocol_handle_acknowledge :: (host: *Host, event: *Event, peer: *Peer, command: Protocol) -> Result_Status {
    if peer.state == .DISCONNECTED || peer.state == .ZOMBIE return .NONE;

    // :Time
    received_sent_time := cast(s64)net_to_host_endian(command.acknowledge.received_sent_time);
    received_sent_time |= host.service_time & 0xFFFF0000;
    if received_sent_time & 0x8000 > host.service_time & 0x8000 then received_sent_time -= 0x10000;

    if host.service_time < received_sent_time then return .NONE;

    peer.last_received_time = host.service_time;
    peer.earliest_timeout = 0;
    round_trip_time := host.service_time - received_sent_time;

    peer_throttle(peer, round_trip_time);
    peer.round_trip_time_variance -= peer.round_trip_time_variance / 4;

    if round_trip_time >= peer.round_trip_time {
        peer.round_trip_time += (round_trip_time - peer.round_trip_time) / 8;
        peer.round_trip_time_variance += (round_trip_time - peer.round_trip_time) / 4;
    } else {
        peer.round_trip_time -= (round_trip_time - peer.round_trip_time) / 8;
        peer.round_trip_time_variance -= (round_trip_time - peer.round_trip_time) / 4;
    }

    if peer.round_trip_time < peer.lowest_round_trip_time then peer.lowest_round_trip_time = peer.round_trip_time;

    if peer.round_trip_time_variance > peer.highest_round_trip_time_variance {
        peer.highest_round_trip_time_variance = peer.round_trip_time_variance;
    }

    if peer.packet_throttle_epoch == 0 || host.service_time - peer.packet_throttle_epoch >= peer.packet_throttle_interval {
        peer.last_round_trip_time = peer.lowest_round_trip_time;
        peer.last_round_trip_time_variance = peer.highest_round_trip_time_variance;
        peer.lowest_round_trip_time = peer.round_trip_time;
        peer.highest_round_trip_time_variance = peer.round_trip_time_variance;
        peer.packet_throttle_epoch = host.service_time;
    }

    received_reliable_seq_number := net_to_host_endian(command.acknowledge.received_reliable_seq_number);
    command_number := protocol_remove_sent_reliable_command(peer, received_reliable_seq_number, command.header.channel_id);

    if peer.state == {
        case .ACKNOWLEDGING_CONNECT;
            if command_number != .VERIFY_CONNECT return .ERROR;
            protocol_notify_connect(host, peer, event);
        case .DISCONNECTING;
            if command_number != .DISCONNECT return .ERROR;
            protocol_notify_disconnect(host, peer, event);
        case .DISCONNECT_LATER;
            if list_empty(*peer.outgoing_reliable_commands) &&
                list_empty(*peer.outgoing_unreliable_commands) &&
                list_empty(*peer.sent_reliable_commands) {

                peer_disconnect(peer, peer.event_data);
            }
    }

    return .NONE;
}

protocol_handle_ping :: (host: *Host, peer: *Peer, command: Protocol) -> Result_Status {
    if peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER {
        return .ERROR;
    } else {
        return .NONE;
    }
}

protocol_handle_connect :: (host: *Host, header: *Protocol_Header, command: Protocol) -> *Peer {
    channel_count := net_to_host_endian(command.connect.channel_count);

    if channel_count < PROTOCOL_MIN_CHANNEL_COUNT || channel_count > PROTOCOL_MAX_CHANNEL_COUNT return null;

    duplicate_peers : u32;
    peer : *Peer;

    for * current_peer: host.peers {
        if current_peer.state == .DISCONNECTED {
            if !peer peer = current_peer;
        } else if current_peer.state != .CONNECTING && in6_equal(current_peer.address.host, host.received_address.host) {
            if current_peer.address.port == host.received_address.port && current_peer.connect_id == command.connect.connect_id return null;

            duplicate_peers += 1;
        }
    }

    if !peer || duplicate_peers >= host.duplicate_peers return null;

    if channel_count > host.channel_limit channel_count = host.channel_limit;

    peer.channels = NewArray(channel_count, Channel);
    peer.state = .ACKNOWLEDGING_CONNECT;
    peer.connect_id = command.connect.connect_id;
    peer.address = host.received_address;
    peer.outgoing_peer_id = net_to_host_endian(command.connect.outgoing_peer_id);
    peer.incoming_bandwidth = net_to_host_endian(command.connect.incoming_bandwidth);
    peer.outgoing_bandwidth = net_to_host_endian(command.connect.outgoing_bandwidth);
    peer.packet_throttle_interval = net_to_host_endian(command.connect.packet_throttle_interval);
    peer.packet_throttle_acceleration = net_to_host_endian(command.connect.packet_throttle_acceleration);
    peer.packet_throttle_deceleration = net_to_host_endian(command.connect.packet_throttle_deceleration);
    peer.event_data = net_to_host_endian(command.connect.data);

    incoming_session_id := ifx command.connect.incoming_session_id == 0xFF then peer.outgoing_session_id else command.connect.incoming_session_id;
    incoming_session_id = (incoming_session_id + 1) & (PROTOCOL_SESSION_MASK >> PROTOCOL_SESSION_SHIFT);
    if incoming_session_id == peer.outgoing_session_id {
        incoming_session_id = (incoming_session_id + 1) & (PROTOCOL_SESSION_MASK >> PROTOCOL_SESSION_SHIFT);
    }
    peer.outgoing_session_id = incoming_session_id;

    outgoing_session_id := ifx command.connect.outgoing_session_id == 0xFF then peer.incoming_session_id else command.connect.outgoing_session_id;
    outgoing_session_id = (outgoing_session_id + 1) & (PROTOCOL_SESSION_MASK >> PROTOCOL_SESSION_SHIFT);

    if outgoing_session_id == peer.incoming_session_id {
        outgoing_session_id = (outgoing_session_id + 1) & (PROTOCOL_SESSION_MASK >> PROTOCOL_SESSION_SHIFT);
    }
    peer.incoming_session_id = outgoing_session_id;

    for * channel: peer.channels {
        channel.outgoing_reliable_seq_number = 0;
        channel.outgoing_unreliable_seq_number = 0;
        channel.incoming_reliable_seq_number = 0;
        channel.incoming_unreliable_seq_number = 0;

        list_clear(*channel.incoming_reliable_commands);
        list_clear(*channel.incoming_unreliable_commands);

        channel.used_reliable_windows = 0;
        memset(channel.reliable_windows.data, 0, size_of(u16)*PEER_RELIABLE_WINDOWS);
    }

    mtu := net_to_host_endian(command.connect.mtu);
    if mtu < PROTOCOL_MIN_MTU mtu = PROTOCOL_MIN_MTU;
    else if mtu > PROTOCOL_MAX_MTU mtu = PROTOCOL_MAX_MTU;
    peer.mtu = mtu;


    if host.outgoing_bandwidth == 0  && peer.incoming_bandwidth == 0 {
        peer.window_size = PROTOCOL_MAX_WINDOW_SIZE;
    } else if host.outgoing_bandwidth == 0 || peer.incoming_bandwidth == 0 {
        peer.window_size = (max(host.outgoing_bandwidth, peer.incoming_bandwidth) / PEER_WINDOW_SIZE_SCALE) * PROTOCOL_MIN_WINDOW_SIZE;
    } else {
        peer.window_size = (min(host.outgoing_bandwidth, peer.incoming_bandwidth) / PEER_WINDOW_SIZE_SCALE) * PROTOCOL_MIN_WINDOW_SIZE;
    }

    if peer.window_size < PROTOCOL_MIN_WINDOW_SIZE then peer.window_size = PROTOCOL_MIN_WINDOW_SIZE;
    else if peer.window_size > PROTOCOL_MAX_WINDOW_SIZE then peer.window_size = PROTOCOL_MAX_WINDOW_SIZE;

    window_size : u32;
    if host.incoming_bandwidth == 0 then window_size = PROTOCOL_MAX_WINDOW_SIZE;
    else window_size = (host.incoming_bandwidth / PEER_WINDOW_SIZE_SCALE) * PROTOCOL_MIN_WINDOW_SIZE;

    if window_size > net_to_host_endian(command.connect.window_size) then window_size = net_to_host_endian(command.connect.window_size);

    if window_size < PROTOCOL_MIN_WINDOW_SIZE then window_size = PROTOCOL_MIN_WINDOW_SIZE;
    else if window_size > PROTOCOL_MAX_WINDOW_SIZE then window_size = PROTOCOL_MAX_WINDOW_SIZE;

    verify_cmd : Protocol;
    verify_cmd.header.command = Protocol_Command.VERIFY_CONNECT | .FLAG_ACKNOWLEDGE;
    verify_cmd.header.channel_id = 0xFF;
    verify_cmd.verify_connect.outgoing_peer_id = host_to_net_endian(peer.incoming_peer_id);
    verify_cmd.verify_connect.incoming_session_id = incoming_session_id;
    verify_cmd.verify_connect.outgoing_session_id = outgoing_session_id;
    verify_cmd.verify_connect.mtu = host_to_net_endian(peer.mtu);
    verify_cmd.verify_connect.window_size = host_to_net_endian(window_size);
    verify_cmd.verify_connect.channel_count = host_to_net_endian(channel_count);
    verify_cmd.verify_connect.incoming_bandwidth = host_to_net_endian(host.incoming_bandwidth);
    verify_cmd.verify_connect.outgoing_bandwidth = host_to_net_endian(host.outgoing_bandwidth);
    verify_cmd.verify_connect.packet_throttle_interval = host_to_net_endian(peer.packet_throttle_interval);
    verify_cmd.verify_connect.packet_throttle_acceleration = host_to_net_endian(peer.packet_throttle_acceleration);
    verify_cmd.verify_connect.packet_throttle_deceleration = host_to_net_endian(peer.packet_throttle_deceleration);
    verify_cmd.verify_connect.connect_id = peer.connect_id;

    peer_queue_outgoing_command(peer, *verify_cmd, null, 0, 0);
    return peer;
}

protocol_handle_disconnect :: (host: *Host, peer: *Peer, command: Protocol) -> Result_Status {
    if peer.state == .DISCONNECTED || peer.state == .ZOMBIE || peer.state == .ACKNOWLEDGING_DISCONNECT then return .NONE;

    peer_reset_queues(peer);

    if peer.state == .CONNECTION_SUCCEEDED || peer.state == .DISCONNECTING || peer.state == .CONNECTING {
        protocol_dispatch_state(host, peer, .ZOMBIE);
    } else if peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER {
        if peer.state == .CONNECTION_PENDING then host.recalculate_bandwidth_limits = true;
        peer_reset(peer);
    } else if command.header.command & .FLAG_ACKNOWLEDGE {
        protocol_change_state(host, peer, .ACKNOWLEDGING_DISCONNECT);
    } else {
        protocol_dispatch_state(host, peer, .ZOMBIE);
    }

    if peer.state != .DISCONNECTED then peer.event_data = net_to_host_endian(command.disconnect.data);

    return .NONE;
}

protocol_handle_send_reliable :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **u8) -> Result_Status {
    if command.header.channel_id >= peer.channels.count || peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER return .ERROR;

    data_length := net_to_host_endian(command.send_reliable.data_length);
    <<current_data += data_length;

    if data_length > host.maximum_packet_size || <<current_data < host.received_data || <<current_data > *host.received_data[host.received_data_length] return .ERROR;

    if peer_queue_incoming_command(peer, command, cast(*u8)(command) + size_of(Protocol_Send_Reliable), data_length, .RELIABLE, 0) == null return .ERROR;

    return .NONE;
}

protocol_handle_send_unreliable :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **u8) -> Result_Status {

    if command.header.channel_id >= peer.channels.count || peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER return .ERROR;

    data_length := net_to_host_endian(command.send_unreliable.data_length);
    <<current_data += data_length;
    if data_length > host.maximum_packet_size || <<current_data < host.received_data || <<current_data > *host.received_data[host.received_data_length] return .ERROR;

    if peer_queue_incoming_command(peer, command, (cast(*u8)command) + size_of(Protocol_Send_Unreliable), data_length, 0, 0) == null then return .ERROR;

    return .NONE;
}

protocol_handle_send_unsequenced :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **u8) -> Result_Status {
    if command.header.channel_id >= peer.channels.count || (peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER) return .ERROR;

    data_length := net_to_host_endian(command.send_unsequenced.data_length);
    <<current_data += data_length;
    
    if data_length > host.maximum_packet_size || <<current_data < host.received_data || <<current_data > *host.received_data[host.received_data_length] return .ERROR;

    unsequenced_group := cast(s64)net_to_host_endian(command.send_unsequenced.unsequenced_group);
    index := unsequenced_group % PEER_UNSEQUENCED_WINDOW_SIZE;

    if unsequenced_group < peer.incoming_unsequenced_group then unsequenced_group += 0x10000;

    if unsequenced_group >= peer.incoming_unsequenced_group + PEER_FREE_UNSEQUENCED_WINDOWS * PEER_UNSEQUENCED_WINDOW_SIZE return .NONE;

    unsequenced_group &= 0xFFFF;

    if unsequenced_group - index != peer.incoming_unsequenced_group {
        peer.incoming_unsequenced_group = cast(u16)(unsequenced_group - index);
        memset(peer.unsequenced_window.data, 0, peer.unsequenced_window.count * size_of(u32));
    } else {
        return .NONE;
    }

    if peer_queue_incoming_command(peer, command, cast(*u8)(command) + size_of(Protocol_Send_Unsequenced), data_length, .UNSEQUENCED, 0) == null then return .ERROR;

    return .NONE;
}

protocol_handle_send_fragment :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **u8) -> Result_Status {
    if command.header.channel_id >= peer.channels.count || peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER return .ERROR;

    fragment_length := net_to_host_endian(command.send_fragment.data_length);
    <<current_data += fragment_length;

    if fragment_length > host.maximum_packet_size || <<current_data < host.received_data || <<current_data > *host.received_data[host.received_data_length] then return .ERROR;

    channel := *peer.channels[command.header.channel_id];
    start_seq_number := net_to_host_endian(command.send_fragment.start_seq_number);
    start_window := start_seq_number / PEER_RELIABLE_WINDOW_SIZE;
    current_window := channel.incoming_reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;

    if start_seq_number < channel.incoming_reliable_seq_number then start_window += PEER_RELIABLE_WINDOWS;

    if start_window < current_window || start_window >= current_window + PEER_FREE_RELIABLE_WINDOWS -1 then return .NONE;

    fragment_number := net_to_host_endian(command.send_fragment.fragment_number);
    fragment_count  := net_to_host_endian(command.send_fragment.fragment_count);
    fragment_offset := net_to_host_endian(command.send_fragment.fragment_offset);
    total_length    := net_to_host_endian(command.send_fragment.total_length);

    // These giant ifs are terrible
    if fragment_count > PROTOCOL_MAX_FRAGMENT_COUNT ||
       fragment_number >= fragment_count ||
       total_length > host.maximum_packet_size ||
       fragment_offset > total_length ||
       fragment_length > total_length - fragment_offset then return .ERROR;

    start_cmd : *Incoming_Command;

    for :reverse channel.incoming_reliable_commands {
        incoming_cmd := cast(*Incoming_Command)it;

        if start_seq_number >= channel.incoming_reliable_seq_number {
            if incoming_cmd.reliable_seq_number < channel.incoming_reliable_seq_number then continue;
        } else if incoming_cmd.reliable_seq_number >= channel.incoming_reliable_seq_number {
            break;
        }

        if incoming_cmd.reliable_seq_number <= start_seq_number {
            if incoming_cmd.reliable_seq_number < start_seq_number then break;

            if incoming_cmd.command.header.command & .MASK != .SEND_FRAGMENT ||
               total_length != incoming_cmd.packet.data_length ||
               fragment_count != incoming_cmd.fragment_count then return .ERROR;

           start_cmd = incoming_cmd;
        }
    }

    if start_cmd == null {
        host_cmd := <<command;
        host_cmd.header.reliable_seq_number = start_seq_number;
        start_cmd = peer_queue_incoming_command(peer, *host_cmd, null, total_length, .RELIABLE, fragment_count);
        if start_cmd == null then return .ERROR;
    }

    if start_cmd.fragments[fragment_number / 32] & (1 << (fragment_number % 32)) {
        start_cmd.fragments_remaining -= 1;
        start_cmd.fragments[fragment_number / 32] |= cast(u32)(1 << (fragment_number % 32));

        if fragment_offset + fragment_length > start_cmd.packet.data_length {
            fragment_length = cast(u16)(start_cmd.packet.data_length - fragment_offset);
        }

        memcpy(start_cmd.packet.data + fragment_offset, (cast(*u8)command) + size_of(Protocol_Send_Fragment), fragment_length);

        if start_cmd.fragments_remaining <= 0 then peer_dispatch_incoming_reliable_commands(peer, channel);
    }

    return .NONE;
}

protocol_handle_send_unreliable_fragment :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **u8) -> Result_Status {
    if command.header.channel_id >= peer.channels.count || (peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER) then return .ERROR;

    fragment_length := net_to_host_endian(command.send_fragment.data_length);
    <<current_data += fragment_length;

    if fragment_length > host.maximum_packet_size || <<current_data < host.received_data || <<current_data > *host.received_data[host.received_data_length] {
        return .ERROR;
    }

    channel := *peer.channels[command.header.channel_id];
    reliable_seq_number := command.header.reliable_seq_number;
    start_seq_number := net_to_host_endian(command.send_fragment.start_seq_number);

    reliable_window := reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;
    current_window := channel.incoming_reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;

    if reliable_seq_number < channel.incoming_reliable_seq_number then reliable_window += PEER_RELIABLE_WINDOWS;

    if reliable_window < current_window || reliable_window >= current_window + PEER_FREE_RELIABLE_WINDOWS - 1 then return .NONE;

    if reliable_seq_number == channel.incoming_reliable_seq_number && start_seq_number <= channel.incoming_unreliable_seq_number then return .NONE;

    fragment_number := net_to_host_endian(command.send_fragment.fragment_number);
    fragment_count  := net_to_host_endian(command.send_fragment.fragment_count);
    fragment_offset := net_to_host_endian(command.send_fragment.fragment_offset);
    total_length    := net_to_host_endian(command.send_fragment.total_length);

    // These giant ifs are terrible
    if fragment_count > PROTOCOL_MAX_FRAGMENT_COUNT ||
       fragment_number >= fragment_count ||
       total_length > host.maximum_packet_size ||
       fragment_offset > total_length ||
       fragment_length > total_length - fragment_offset then return .ERROR;

    start_cmd : *Incoming_Command;

    for :reverse channel.incoming_unreliable_commands {
        incoming_cmd := cast(*Incoming_Command)it;

        if reliable_seq_number >= channel.incoming_reliable_seq_number {
            if incoming_cmd.reliable_seq_number < channel.incoming_reliable_seq_number then continue;
        } else if incoming_cmd.reliable_seq_number >= channel.incoming_reliable_seq_number {
            break;
        }

        if incoming_cmd.reliable_seq_number < reliable_seq_number then break;
        if incoming_cmd.reliable_seq_number > reliable_seq_number then continue;

        if incoming_cmd.unreliable_seq_number <= start_seq_number {
            if incoming_cmd.unreliable_seq_number < start_seq_number then break;

            if incoming_cmd.command.header.command & .MASK != .SEND_UNRELIABLE_FRAGMENT ||
               total_length != incoming_cmd.packet.data_length ||
               fragment_count != incoming_cmd.fragment_count then return .ERROR;

            start_cmd = incoming_cmd;
            break;
        }
    }

    if start_cmd == null {
        start_cmd = peer_queue_incoming_command(peer, command, null, total_length, .UNRELIABLE_FRAGMENT, fragment_count);

        if start_cmd == null then return .ERROR;
    }

    if start_cmd.fragments[fragment_number / 32] & 1 << (fragment_number %32) == 0 {
        start_cmd.fragments_remaining -= 1;
        start_cmd.fragments[fragment_number / 32] |= cast(u32)(1 << (fragment_number % 32));

        if fragment_offset + fragment_length > start_cmd.packet.data_length {
            fragment_length = cast(u16)(start_cmd.packet.data_length - fragment_offset);
        }

        memcpy(start_cmd.packet.data + fragment_offset, cast(*u8)(command) + size_of(Protocol_Send_Fragment), fragment_length);

        if start_cmd.fragments_remaining <= 0 then peer_dispatch_incoming_unreliable_commands(peer, channel);
    }

    return .NONE;
}

protocol_handle_bandwidth_limit :: (host: *Host, peer: *Peer, command: *Protocol) -> Result_Status {
    if peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER then return .ERROR;

    if peer.incoming_bandwidth != 0 then host.bandwidth_limited_peers -= 1;

    peer.incoming_bandwidth = net_to_host_endian(command.bandwidth_limit.incoming_bandwidth);

    if peer.incoming_bandwidth != 0 then host.bandwidth_limited_peers += 1;

    peer.outgoing_bandwidth = net_to_host_endian(command.bandwidth_limit.outgoing_bandwidth);

    if peer.incoming_bandwidth == 0 && host.outgoing_bandwidth == 0 {
        peer.window_size = PROTOCOL_MAX_WINDOW_SIZE;
    } else if peer.incoming_bandwidth == 0 || host.outgoing_bandwidth == 0 {
        peer.window_size = (max(peer.incoming_bandwidth, host.outgoing_bandwidth) / PEER_WINDOW_SIZE_SCALE) * PROTOCOL_MIN_WINDOW_SIZE;
    } else {
        peer.window_size = (min(peer.incoming_bandwidth, host.outgoing_bandwidth) / PEER_WINDOW_SIZE_SCALE) * PROTOCOL_MIN_WINDOW_SIZE;
    }
    
    if peer.window_size < PROTOCOL_MIN_WINDOW_SIZE {
        peer.window_size = PROTOCOL_MIN_WINDOW_SIZE;
    } else if peer.window_size > PROTOCOL_MAX_WINDOW_SIZE {
        peer.window_size = PROTOCOL_MAX_WINDOW_SIZE;
    }

    return .NONE;
}

protocol_handle_throttle_configure :: (host: *Host, peer: *Peer, command: *Protocol) -> Result_Status {
    if peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER then return .ERROR;

    peer.packet_throttle_interval = net_to_host_endian(command.throttle_configure.packet_throttle_interval);
    peer.packet_throttle_acceleration = net_to_host_endian(command.throttle_configure.packet_throttle_acceleration);
    peer.packet_throttle_deceleration = net_to_host_endian(command.throttle_configure.packet_throttle_deceleration);

    return .NONE;
}

protocol_notify_connect :: (host: *Host, peer: *Peer, event: *Event) {
    host.recalculate_bandwidth_limits = true;

    if event != null {
        protocol_change_state(host, peer, .CONNECTED);

        peer.total_data_sent = 0;
        peer.total_data_received = 0;
        peer.total_packets_sent = 0;
        peer.total_packets_lost = 0;

        event.type = .CONNECT;
        event.peer = peer;
        event.data = peer.event_data;
    } else {
        protocol_dispatch_state(host, peer, ifx peer.state == .CONNECTING then Peer_State.CONNECTION_SUCCEEDED else Peer_State.CONNECTION_PENDING);
    }
}

protocol_notify_disconnect :: (host: *Host, peer: *Peer, event: *Event) {
    if peer.state >= .CONNECTION_PENDING then host.recalculate_bandwidth_limits = true;

    if peer.state != .CONNECTING && peer.state < .CONNECTION_SUCCEEDED {
        peer_reset(peer);
    } else if event != null {
        event.type = .DISCONNECT;
        event.peer = peer;
        event.data = 0;

        peer_reset(peer);
    } else {
        peer.event_data = 0;
        protocol_dispatch_state(host, peer, .ZOMBIE);
    }
}

protocol_notify_disconnect_timeout :: (host: *Host, peer: *Peer, event: *Event) {
    if peer.state >= .CONNECTION_PENDING host.recalculate_bandwidth_limits = true;

    if peer.state != .CONNECTING && peer.state < .CONNECTION_SUCCEEDED {
        peer_reset(peer);
    } else if event != null {
        event.type = .DISCONNECT_TIMEOUT;
        event.peer = peer;
        event.data = 0;

        peer_reset(peer);
    } else {
        peer.event_data = 0;
        protocol_dispatch_state(host, peer, .ZOMBIE);
    }
}


