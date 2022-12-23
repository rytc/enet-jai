PROTOCOL_MAX_PEER_ID       :: 0xFFF;
PROTOCOL_MAX_CHANNEL_COUNT :: 255;
PROTOCOL_MIN_CHANNEL_COUNT :: 1;
PROTOCOL_MAX_WINDOW_SIZE   :: 65536;
PROTOCOL_MIN_WINDOW_SIZE   :: 4096;
PROTOCOL_MAX_PACKET_COMMANDS :: 32;
PROTOCOL_MAX_MTU             :: 4096;
PROTOCOL_MIN_MTU             :: 576;
PROTOCOL_SESSION_SHIFT       :: 12;
PROTOCOL_SESSION_MASK        :: 3 << 12;

PROTOCOL_FLAG_ACKNOWLEDGE :u32: 1 << 7;
PROTOCOL_FLAG_UNSEQUENCED :u32: 1 << 6;
PROTOCOL_FLAG_COMPRESSED  :u32: 1 << 14;
PROTOCOL_FLAG_SENT_TIME   :u32: 1 << 15;
PROTOCOL_FLAG_MASK        :u32: PROTOCOL_FLAG_COMPRESSED | PROTOCOL_FLAG_SENT_TIME;

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
PROTOCOL_COMMAND_COUNT           :: 13;
PROTOCOL_COMMAND_MASK            :: 0x0F;

Protocol_Header :: struct {
    peer_id : u16;
    sent_time : u16;
}

Protocol_Command_Header :: struct {
    command : u8;
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
                !list_empty(*peer.sent_reliable_commands) && service_time >= peer.next_timeout &&
                protocol_check_timeouts(host, peer, event) == 1 {

                if event != null && event.type != .NONE { 
                    return 1;
                } else {
                    continue;
                }
            }


            if list_empty(*peer.sent_reliable_commands) && 
                service_time - peer.last_received_time >= peer.ping_interval &&
                peer.mtu - host.packet_size >= size_of(Protocol_Ping) && 
                (list_empty(*peer.outgoing_reliable_commands) || 
                protocol_send_reliable_outgoing_commands(host, peer)) {

                peer_ping(peer);
                protocol_send_reliable_outgoing_commands(host, peer);
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
                // offset_of sent_time Protocol_Header
                host.buffers[0].length = size_of(u16);

            }

            // @TODO :compression
            // if host.compressor.context != null && host.compressor.compress != null 

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
            print("sent packet of size %\n", sent_length);
            protocol_remove_sent_unreliable_commands(peer);

            if sent_length < 0 {
                host.buffers[0].data = null;
                return -1;
            }

            host.total_sent_data += xx sent_length;
            peer.total_data_sent += xx sent_length;
            host.total_sent_packets += 1;

            if !host.continue_sending then break;
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

        print("received packet of size %\n", received_length);

        // @TODO
        // if host.intercept !== null { }

        if protocol_handle_incoming_commands(host, event) == {
            case 1; return 1;
            case -1; return -1;
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
        }
    }

    return 0;
}

protocol_send_acknowledgements :: (host: *Host, peer: *Peer) {
    cmd_index := host.command_count;
    buffer_index := host.buffer_count;
    command := *host.commands[cmd_index];
    buffer := *host.buffers[buffer_index];

    current_ack := list_begin(*peer.acknowledgements);

    while current_ack != list_end(*peer.acknowledgements) {

        if cmd_index >= PROTOCOL_MAX_PACKET_COMMANDS ||
        buffer_index >= xx MAX_BUFFER_COUNT ||
        peer.mtu - host.packet_size < size_of(Protocol_Acknowledge) {

            host.continue_sending = true;
            break;
        }


        ack := cast(*Acknowledgement)current_ack;
        current_ack = list_next(ack);

        buffer.data = command;
        buffer.length = size_of(Protocol_Acknowledge);
        host.packet_size += xx buffer.length;

        reliable_seq_number := host_to_net_endian(ack.command.header.reliable_seq_number);

        command.header.command = PROTOCOL_COMMAND_ACKNOWLEDGE;
        command.header.channel_id = ack.command.header.channel_id;
        command.header.reliable_seq_number = reliable_seq_number;
        command.acknowledge.received_reliable_seq_number = reliable_seq_number;
        command.acknowledge.received_sent_time = host_to_net_endian(cast(u16)ack.sent_time);

        if ack.command.header.command & PROTOCOL_COMMAND_MASK == PROTOCOL_COMMAND_DISCONNECT then protocol_dispatch_state(host, peer, .ZOMBIE);

        list_remove(ack);
        free(ack);

        command += 1;
        buffer += 1;
    }

    host.command_count = cast(u32)(command - host.commands.data); 
    host.buffer_count = cast(u32)(buffer - host.buffers.data);
}

protocol_check_timeouts :: (host: *Host, peer: *Peer, event: *Event) -> int {

    current_cmd := list_begin(*peer.sent_reliable_commands);
    insert_pos := list_begin(*peer.outgoing_reliable_commands);

    while current_cmd != list_end(*peer.sent_reliable_commands) {
        outgoing_cmd := cast(*Outgoing_Command)current_cmd;

        current_cmd = list_next(current_cmd);

        // :Time
        service_time := to_milliseconds(host.service_time);
        if service_time - outgoing_cmd.sent_time < outgoing_cmd.round_trip_timeout {
            continue;
        }

        // :Time
        if peer.earliest_timeout == 0 || outgoing_cmd.sent_time < peer.earliest_timeout {
            peer.earliest_timeout = outgoing_cmd.sent_time;
        }

        // @TODO :giant_if
        // :Time
        if peer.earliest_timeout != 0 && (
            service_time - peer.earliest_timeout >= peer.timeout_maximum ||
            (outgoing_cmd.round_trip_timeout >= outgoing_cmd.round_trip_timeout_limit &&
            service_time - peer.earliest_timeout >= peer.timeout_minimum)) {

            protocol_notify_disconnect_timeout(host, peer, event);
            return 1;
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

    return 0;
}

protocol_send_reliable_outgoing_commands :: (host: *Host, peer: *Peer) -> bool {
    cmd_index := host.command_count;
    buffer_index := host.buffer_count;

    cmd := *host.commands[cmd_index];
    buffer := *host.buffers[buffer_index];

    window_wrap := false;
    window_exceeded := true;
    can_ping := true;

    current_cmd := list_begin(*peer.outgoing_reliable_commands);

    while current_cmd != list_end(*peer.outgoing_reliable_commands) {
        outgoing_cmd := cast(*Outgoing_Command)current_cmd;

        channel := ifx outgoing_cmd.command.header.channel_id < peer.channels.count then *peer.channels[outgoing_cmd.command.header.channel_id] else cast(*Channel)null;
        reliable_window := outgoing_cmd.reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;

        if channel != null {
            // BRO WHY DO THEY DO THIS
            // @TODO :giant_if
            if !window_wrap && outgoing_cmd.send_attempts < 1 &&
            !(outgoing_cmd.reliable_seq_number % PEER_RELIABLE_WINDOW_SIZE) && 
            channel.reliable_windows[(reliable_window + PEER_RELIABLE_WINDOWS - 1) % PEER_RELIABLE_WINDOWS] >= PEER_RELIABLE_WINDOW_SIZE ||
            channel.used_reliable_windows & ((((1 << PEER_FREE_RELIABLE_WINDOWS) - 1) << reliable_window | (((1 << PEER_FREE_RELIABLE_WINDOWS) - 1) >> (PEER_RELIABLE_WINDOWS - reliable_window)))) {

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

                if window_exceeded {
                    current_cmd = list_next(current_cmd);
                    continue;
                }
            }
        }

        can_ping = false;

        cmd_size := PROTOCOL_COMMAND_SIZES[outgoing_cmd.command.header.command & PROTOCOL_COMMAND_MASK];

        // @TODO :giant_if
        if cmd_index >= PROTOCOL_MAX_PACKET_COMMANDS ||
            buffer_index + 1 >= cast(u32)MAX_BUFFER_COUNT ||
            peer.mtu - host.packet_size < cmd_size ||
            (outgoing_cmd.packet != null && cast(u16)(peer.mtu - host.packet_size) < cast(u16)(cmd_size + outgoing_cmd.fragment_length)) {

            host.continue_sending = true;
            break;
        }

        current_cmd = list_next(current_cmd);

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
        if list_empty(*peer.sent_reliable_commands) then peer.next_timeout = to_milliseconds(host.service_time) + outgoing_cmd.round_trip_timeout;

        list_insert(list_end(*peer.sent_reliable_commands), list_remove(outgoing_cmd));

        outgoing_cmd.sent_time = cast(u32)to_milliseconds(host.service_time);

        buffer.data = cmd;
        buffer.length = cmd_size;

        host.packet_size += cast(u32)buffer.length;
        host.header_flags |= PROTOCOL_FLAG_SENT_TIME;

        <<cmd = outgoing_cmd.command;

        if outgoing_cmd.packet {
            buffer_index += 1;
            buffer := *host.buffers[buffer_index];
            buffer.data = outgoing_cmd.packet.data + outgoing_cmd.fragment_offset;
            buffer.length = outgoing_cmd.fragment_length;
            host.packet_size += outgoing_cmd.fragment_length;
            peer.reliable_data_in_transit += outgoing_cmd.fragment_length;
        }

        peer.packets_sent += 1;
        peer.total_packets_sent += 1;

        // cmd_index += 1;
        cmd += 1;
        buffer += 1;
    }

    // host.command_count = cmd_index - host.command_count;
    host.command_count = cast(u32)(cmd - host.commands.data);
    host.buffer_count = cast(u32)(buffer - host.buffers.data); // buffer_index - host.buffer_count;

    return can_ping;
}

protocol_send_unreliable_outgoing_commands :: (host: *Host, peer: *Peer) -> int {
    log_error("TODO: protocol_send_unreliable_outgoing_commands is not implemented\n");
}

protocol_remove_sent_unreliable_commands :: (peer: *Peer) -> int {
    while !list_empty(*peer.sent_unreliable_commands) {
        outgoing_cmd := cast(*Outgoing_Command)list_front(*peer.sent_unreliable_commands);
        list_remove(outgoing_cmd);

        print("removing unreliable command!\n");

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

protocol_handle_incoming_commands :: (host: *Host, event: *Event) -> int {
    // offset_of sent_time of Protocol_Header
    if host.received_data_length < size_of(u16) return 0;

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
        return 0;
    } else {
        peer = *host.peers[peer_id];

        is_address_equal := in6_equal(host.received_address.host, peer.address.host);
        is_port_equal := host.received_address.port == peer.address.port;

        if peer.state == .DISCONNECTED || peer.state == .ZOMBIE ||
            ((!is_address_equal || !is_port_equal)) ||
            (peer.outgoing_peer_id < PROTOCOL_MAX_PEER_ID && session_id != peer.incoming_session_id) {

            return 0;
        }
    }

    // @TODO :compression support
    if flags & PROTOCOL_FLAG_COMPRESSED {
        log_error("enet: compression is not yet supported\n");
    }

    // @TODO :checksum support
    // if host.checksum != null { }


    if peer {
        peer.address.host = host.received_address.host;
        peer.address.port = host.received_address.port;
        peer.incoming_data_total += host.received_data_length;
        peer.total_data_received +=  host.received_data_length;
    }

    current_data := host.received_data + header_size;
    error := false; // @TODO :refactor this isn't actually used/needed

    while current_data < host.received_data + host.received_data_length {

        command := cast(*Protocol)current_data;

        if current_data + size_of(Protocol_Command_Header)  > host.received_data + host.received_data_length {
            break;
        }

        command_number := command.header.command & PROTOCOL_COMMAND_MASK;
        if command_number > PROTOCOL_COMMAND_COUNT break;

        command_size := PROTOCOL_COMMAND_SIZES[command_number];

        if command_size == 0 || current_data + command_size > host.received_data + host.received_data_length break;

        current_data += command_size;

        if peer == null && (command_number != PROTOCOL_COMMAND_CONNECT || current_data < host.received_data + host.received_data_length) break;

        command.header.reliable_seq_number = net_to_host_endian(command.header.reliable_seq_number);

        print("incoming command %\n", command_number);
        if command_number == {
            case PROTOCOL_COMMAND_ACKNOWLEDGE; if protocol_handle_acknowledge(host, event, peer, command) error = true;
            case PROTOCOL_COMMAND_CONNECT; 
                if peer != null  {
                    error = true;
                }
                peer = protocol_handle_connect(host, header, command);
                if peer == null { error = true; break; }
            case PROTOCOL_COMMAND_VERIFY_CONNECT; if protocol_handle_verify_connect(host, event, peer, command) { error = true; break; }
            case PROTOCOL_COMMAND_DISCONNECT; if protocol_handle_disconnect(host, peer, command) { error = true; break; }
            case PROTOCOL_COMMAND_PING; if protocol_handle_ping(host, peer, command) { error = true; break; }
            case; log_error("TODO: Command % not handled in protocol_handle_incoming_commands\n", command_number); break;
        }

        if peer == null {
            print("Peer is null. Command number %\n", command_number);
        }
        assert(peer != null);
        if command.header.command & PROTOCOL_FLAG_ACKNOWLEDGE != 0 {
            if !(flags & PROTOCOL_FLAG_SENT_TIME) break;

            sent_time := net_to_host_endian(header.sent_time);

            if peer.state == {
                case .DISCONNECTING; #through;
                case .ACKNOWLEDGING_CONNECT; #through;
                case .DISCONNECTED; #through;
                case .ZOMBIE; // do nothing 
                case .ACKNOWLEDGING_DISCONNECT;
                    if command.header.command & PROTOCOL_COMMAND_MASK == PROTOCOL_COMMAND_DISCONNECT peer_queue_acknowledgement(peer, command, sent_time);
                case;
                    print("Queueing acknowledgement\n");
                    peer_queue_acknowledgement(peer, command, sent_time);
            }
        }
    }

    if event != null && event.type != .NONE return 1;

    return 0;
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

protocol_dispatch_state :: (host: *Host, peer: *Peer, state: Peer_State) {
    log_error("TODO: protocol_dispatch_state is not implemented\n");
}

protocol_handle_acknowledge :: (host: *Host, event: *Event, peer: *Peer, command: Protocol) -> int {
    service_time := to_milliseconds(host.service_time);

    if peer.state == .DISCONNECTED || peer.state == .ZOMBIE return 0;

    // :Time
    received_sent_time := net_to_host_endian(command.acknowledge.received_sent_time);
    received_sent_time |= cast(u16)(service_time & 0xFFFF0000);
    if received_sent_time & 0x8000 > service_time & 0x8000 then received_sent_time -= 0x1000;

    if service_time < received_sent_time then return 0;

    peer.last_received_time = service_time;
    peer.earliest_timeout = 0;
    round_trip_time := service_time - received_sent_time;

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

    if peer.packet_throttle_epoch == 0 || service_time - peer.packet_throttle_epoch >= peer.packet_throttle_interval {
        peer.last_round_trip_time = peer.lowest_round_trip_time;
        peer.last_round_trip_time_variance = peer.highest_round_trip_time_variance;
        peer.lowest_round_trip_time = peer.round_trip_time;
        peer.highest_round_trip_time_variance = peer.round_trip_time_variance;
        peer.packet_throttle_epoch = service_time;
    }

    received_reliable_seq_number := net_to_host_endian(command.acknowledge.received_reliable_seq_number);
    command_number := protocol_remove_sent_reliable_command(peer, received_reliable_seq_number, command.header.channel_id);

    if peer.state == {
        case .ACKNOWLEDGING_CONNECT;
            if command_number != PROTOCOL_COMMAND_VERIFY_CONNECT return -1;
            protocol_notify_connect(host, peer, event);
        case .DISCONNECTING;
            if command_number != PROTOCOL_COMMAND_DISCONNECT return -1;
            protocol_notify_disconnect(host, peer, event);
        case .DISCONNECT_LATER;
            if list_empty(*peer.outgoing_reliable_commands) &&
                list_empty(*peer.outgoing_unreliable_commands) &&
                list_empty(*peer.sent_reliable_commands) {

                peer_disconnect(peer, peer.event_data);
            }
    }

    return 0;
}

protocol_handle_ping :: (host: *Host, peer: *Peer, command: Protocol) -> int {
    result := ifx peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER then -1 else 0;
    return  result;
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
    verify_cmd.header.command = cast(u8)(PROTOCOL_COMMAND_VERIFY_CONNECT | PROTOCOL_FLAG_ACKNOWLEDGE);
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

    print("send verify\n");
    peer_queue_outgoing_command(peer, *verify_cmd, null, 0, 0);
    return peer;
}

protocol_handle_disconnect :: (host: *Host, peer: *Peer, command: Protocol) -> int {
    log_error("TODO: protocol_handle_disconnect is not implemented\n");
}

protocol_handle_verify_connect :: (host: *Host, event: *Event, peer: *Peer, command: Protocol) -> int {
    if peer.state != .CONNECTING then return 0;

    channel_count := net_to_host_endian(command.verify_connect.channel_count);

    // @TODO :giant_if
    if channel_count < PROTOCOL_MIN_CHANNEL_COUNT || channel_count > PROTOCOL_MAX_CHANNEL_COUNT ||
        net_to_host_endian(command.verify_connect.packet_throttle_interval) != peer.packet_throttle_interval ||
        net_to_host_endian(command.verify_connect.packet_throttle_acceleration) != peer.packet_throttle_acceleration ||
        net_to_host_endian(command.verify_connect.packet_throttle_deceleration) != peer.packet_throttle_deceleration ||
        command.verify_connect.connect_id != peer.connect_id {
        
        peer.event_data = 0;
        protocol_dispatch_state(host, peer, .ZOMBIE);
        return -1;
    }

    protocol_remove_sent_reliable_command(peer, 1, 0xFF);

    if channel_count < peer.channels.count {
        //peer.channel_count = channel_count;
        // This is probably fine, just means 
        log_error("Warning: The peer verify_connect.channel_count is different than what was allocated on connect.\n");
        log_error("   Verified % but allocated %\n", channel_count, peer.channels.count);
        log_error("   This is probably fine, it just means there's a mismatch between the server's host_create, the client's host_create and host_connect channel counts.");
        array_free(peer.channels);
        peer.channels = NewArray(channel_count, Channel);
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
    return 0;
}

protocol_remove_sent_reliable_command :: (peer: *Peer, reliable_seq_number: u16, channel_id: u8) -> int {
    current_cmd := list_begin(*peer.sent_reliable_commands);
    outgoing_cmd : *Outgoing_Command;
    was_sent := true;

    while current_cmd != list_end(*peer.sent_reliable_commands) {
        outgoing_cmd = cast(*Outgoing_Command)current_cmd;

        if outgoing_cmd.reliable_seq_number == reliable_seq_number && outgoing_cmd.command.header.channel_id == channel_id then break;

        current_cmd = list_next(current_cmd);
    }

    if current_cmd == list_end(*peer.sent_reliable_commands) {
        current_cmd = list_begin(*peer.outgoing_reliable_commands);
        while current_cmd != list_end(*peer.outgoing_reliable_commands) {
            
            outgoing_cmd = cast(*Outgoing_Command)current_cmd;

            if outgoing_cmd.send_attempts < 1 then return PROTOCOL_COMMAND_NONE;

            if outgoing_cmd.reliable_seq_number == reliable_seq_number && outgoing_cmd.command.header.channel_id == channel_id then break;

            current_cmd = list_next(current_cmd);
        }

        if current_cmd == list_end(*peer.outgoing_reliable_commands) then return PROTOCOL_COMMAND_NONE;

        was_sent = false;
    }

    if outgoing_cmd == null then return PROTOCOL_COMMAND_NONE;

    if channel_id < peer.channels.count {
        channel := *peer.channels[channel_id];
        reliable_window := reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;
        if channel.reliable_windows[reliable_window] > 0 {
            channel.reliable_windows[reliable_window] -= 1;
            if !channel.reliable_windows[reliable_window] then channel.used_reliable_windows &= ~(cast(u16)1 << reliable_window);
        }
    }

    cmd_number := outgoing_cmd.command.header.command & PROTOCOL_COMMAND_MASK;
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
    log_error("TODO: protocol_notify_disconnect not implemented\n");
}

