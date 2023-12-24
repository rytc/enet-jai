
Host :: struct {
    peers:           []Peer;
    connected_peers: u32;
    bandwidth_limited_peers: u32;
    socket:  Socket;
    address: Address;
    received_address: Address;
    random_seed:     u32;
    channel_limit:   u32;
    mtu:             u32;
    duplicate_peers: u32;

    service_time_offset: Apollo_Time;
    service_time:        s64;

    incoming_bandwidth: u32;
    outgoing_bandwidth: u32;
    bandwidth_throttle_epoch: s64;
    recalculate_bandwidth_limits: bool;

    commands: [PROTOCOL_MAX_PACKET_COMMANDS]Protocol;
    command_count: u32;

    header_flags: u32;
    buffers: [MAX_BUFFER_COUNT]Buffer;
    buffer_count: u32;

    total_sent_packets: u32;
    total_sent_data:    u64;

    maximum_packet_size: u32;
    packet_data: [2 * PROTOCOL_MAX_MTU]u8; // 2D array in C. Index [1] is used for compression which is TODO
    packet_size:            u32;
    total_received_packets: u32;

    received_data:              *u8;
    received_data_length:       u32;
    total_received_data_length: u32;
    maximum_waiting_data:       u32;

    continue_sending: bool;
    dispatch_queue:   List;
}

host_create :: (address: *Address, peer_count: int, channel_limit: int, incoming_bandwidth: int, outgoing_bandwidth: int) -> *Host, bool {
    host: *Host;

    if peer_count < 0 || peer_count >= PROTOCOL_MAX_PEER_ID {
        log_error("Invalid peer count 0 < % < %", peer_count, PROTOCOL_MAX_PEER_ID);
        return host, false; 
    }

    host = New(Host);
    host.peers = NewArray(peer_count, Peer);
    host.socket = socket_create();

    if host.socket != INVALID_SOCKET set_socket_options(host.socket, .IPV6_V6ONLY, 0);

    if host.socket == INVALID_SOCKET || (socket_bind(host.socket, address) < 0 && address != null) {
        log_error("Failed to create and bind socket: %\n", WSAGetLastError());

        socket_destroy(host.socket);
        array_free(host.peers);
        free(host);

        return host, false;
    }

    set_socket_options(host.socket, .NONEBLOCK, 1);
    set_socket_options(host.socket, .BROADCAST, 1);
    set_socket_options(host.socket, .RECEIVE_BUFF, HOST_RECEIVE_BUFFER_SIZE);
    set_socket_options(host.socket, .SEND_BUFF, HOST_SEND_BUFFER_SIZE);
    set_socket_options(host.socket, .IPV6_V6ONLY, 0);

    if address != null && !get_socket_address(host.socket, *host.address) {
        host.address = address.*;
    }

    if channel_limit == 0 || channel_limit > PROTOCOL_MAX_CHANNEL_COUNT {
        channel_limit = PROTOCOL_MAX_CHANNEL_COUNT;
    }

    host.random_seed = (cast(u32)host) % U32_MAX;
    host.random_seed += xx random_seed(); 
    host.random_seed = (host.random_seed << 16) | (host.random_seed >> 16);
    host.channel_limit = cast(u32)channel_limit;
    host.incoming_bandwidth = cast(u32)incoming_bandwidth;
    host.outgoing_bandwidth = cast(u32)outgoing_bandwidth;
    host.mtu = HOST_DEFAULT_MTU;
    host.received_address.host = HOST_ANY;
    host.received_address.port = 0;
    host.duplicate_peers = PROTOCOL_MAX_PEER_ID;
    host.maximum_packet_size = HOST_DEFAULT_MAX_PACKET_SIZE;
    host.maximum_waiting_data = HOST_DEFAULT_MAX_WAITING_DATA; 
    host.service_time_offset = current_time_monotonic();

    list_clear(*host.dispatch_queue);

    for * peer: host.peers {
        peer.host = host;
        peer.incoming_peer_id = cast(u16)it_index;
        peer.outgoing_session_id = 0xFF;
        peer.incoming_session_id = 0xFF;
        peer.data = null;

        list_clear(*peer.outgoing_reliable_commands);
        list_clear(*peer.outgoing_unreliable_commands);
        list_clear(*peer.sent_reliable_commands);
        list_clear(*peer.sent_unreliable_commands);
        list_clear(*peer.acknowledgements);
        list_clear(*peer.dispatched_commands);

        peer_reset(peer);
    }

    return host, true;
}

host_destroy :: (host: *Host) {
    socket_destroy(host.socket);
    for peer: host.peers  {
        array_free(peer.channels);
    }
    array_free(host.peers);
    free(host);
}

host_connect :: (host: *Host, address: Address, channel_count: int, data: u32) -> *Peer {
    current_peer : *Peer;

    for * host.peers {
        if it.state == .DISCONNECTED {
            current_peer = it;
            break;
        }
    }

    // No available peers
    if current_peer == null return null;

    assert(channel_count > 0 && channel_count < PROTOCOL_MAX_CHANNEL_COUNT);

    current_peer.channels = NewArray(channel_count, Channel);
    current_peer.state = .CONNECTING;
    current_peer.address = address;
    current_peer.connect_id = host.random_seed + 1;

    if host.outgoing_bandwidth == 0 {
        current_peer.window_size = PROTOCOL_MAX_WINDOW_SIZE;
    } else {
        current_peer.window_size = (host.outgoing_bandwidth / PEER_WINDOW_SIZE_SCALE) * PROTOCOL_MIN_WINDOW_SIZE;
    }

    if current_peer.window_size < PROTOCOL_MIN_WINDOW_SIZE {
        current_peer.window_size = PROTOCOL_MIN_WINDOW_SIZE;
    } else if current_peer.window_size > PROTOCOL_MAX_WINDOW_SIZE {
        current_peer.window_size = PROTOCOL_MAX_WINDOW_SIZE; 
    }

    for * channel: current_peer.channels {
        channel_reset(channel);
    }

    command : Protocol;
    command.header.command                       = Protocol_Command.CONNECT | .FLAG_ACKNOWLEDGE;
    command.header.channel_id                    = 0xFF;
    command.connect.outgoing_peer_id             = host_to_net_endian_16(current_peer.incoming_peer_id);
    command.connect.incoming_session_id          = current_peer.incoming_session_id;
    command.connect.outgoing_session_id          = current_peer.outgoing_session_id;
    command.connect.mtu                          = host_to_net_endian_32(current_peer.mtu);
    command.connect.window_size                  = host_to_net_endian_32(current_peer.window_size);
    command.connect.channel_count                = host_to_net_endian_32(cast(u32)channel_count);
    command.connect.incoming_bandwidth           = host_to_net_endian_32(cast(u32)host.incoming_bandwidth);
    command.connect.outgoing_bandwidth           = host_to_net_endian_32(cast(u32)host.outgoing_bandwidth);
    command.connect.packet_throttle_interval     = host_to_net_endian_32(current_peer.packet_throttle_interval);
    command.connect.packet_throttle_acceleration = host_to_net_endian_32(current_peer.packet_throttle_acceleration);
    command.connect.packet_throttle_deceleration = host_to_net_endian_32(current_peer.packet_throttle_deceleration);
    command.connect.connect_id                   = current_peer.connect_id;
    command.connect.data                         = host_to_net_endian_32(data);

    peer_queue_outgoing_command(current_peer, *command, null, 0, 0);

    return current_peer;
}

// timeout: milliseconds to wait for incoming packets. Zero means it won't wait and will return immediately
// Returns SUCCESS if it handled an incoming command. There may be more commands to handle on SUCCESS
host_service :: (host: *Host, event: *Event, timeout: s64) -> Result_Status {
    #if DEBUG_FRAME_CAPTURE {
        debug_begin_frame();
        defer debug_end_frame();
    }

    if event {
        event.type = .NONE;
        event.peer = null;
        event.packet = null;

        // This returns events to the caller. Returns 1 event for 1 peer,
        // subsequent calls will either return the next event or the next event
        // for the peer. If none of the peers have events, then continue.
        if protocol_dispatch_incoming_commands(host, event) == .SUCCESS return .SUCCESS;
    }

    host_update_service_time(host);
    timeout += host.service_time;

    while true {
        if time_difference(host.service_time, host.bandwidth_throttle_epoch) > HOST_BANDWIDTH_THROTTLE_INTERVAL {
            host_bandwidth_throttle(host);
        }

        send_outgoing :: () #expand {
            send_out_status := protocol_send_outgoing_commands(`host, `event, true);
            if send_out_status == {
                case .SUCCESS;
                    `return .SUCCESS;
                case .ERROR;
                    #if DEBUG_PRINT {
                        log_error("Error sending outgoing packets\n");
                    }
                    `return .ERROR;
            }
        }

        send_outgoing(); 

        receive_in_status := protocol_receive_incoming_commands(host, event);
        if receive_in_status == {
            case .SUCCESS; 
                return .SUCCESS;
            case .ERROR;
                #if DEBUG_PRINT {
                    log_error("Error receiving incoming packets\n");
                }
                return .ERROR;
        }

        send_outgoing();

        if event {
            dispatch_incoming_status := protocol_dispatch_incoming_commands(host, event);
            if dispatch_incoming_status == {
                case .SUCCESS; 
                    return .SUCCESS;
                case .ERROR;
                    #if DEBUG_PRINT {
                        log_error("Error dispatching incoming commands\n");
                    }
                    return .ERROR;
            }
        }

        if host.service_time >= timeout then {
            return .NONE;
        }

        wait_condition: Socket_Wait;

        // Wait `timeout` amount of time for incoming packets
        while true {
            host_update_service_time(host);
            if host.service_time >= timeout then return .NONE;

            wait_condition = Socket_Wait.RECEIVE | .INTERRUPT;
            if socket_wait(host.socket, *wait_condition, time_difference(host.service_time, timeout)) == .ERROR {
                return .ERROR;
            }

            if !(wait_condition & .INTERRUPT) then break;
        }

        host_update_service_time(host);
        if !(wait_condition & .RECEIVE) break;
    }

    return .NONE;
}

host_send_raw :: (host: *Host, address: *Address, data: []u8) {
    buffer: [1]Buffer;
    buffer[0].data = data.data;
    buffer[0].length = data.count;
    socket_send(host.socket, address, buffer, 1);
}

host_send_raw :: (host: *Host, address: *Address, data: *$T) {
    buffer: [1]Buffer;
    buffer[0].data = data;
    buffer[0].length = size_of(T);
    socket_send(host.socket, address, buffer, 1);
}

host_flush :: (host: *Host) {
    host_update_service_time(host);
    protocol_send_outgoing_commands(host, null, false);
}

// 0 means unlimited bandwidth
host_bandwidth_limit :: (host: *Host, incoming_bandwidth: int, outgoing_bandwidth: int) {
    if incoming_bandwidth < 0 then incoming_bandwidth = 0;
    else if incoming_bandwidth > U32_MAX then incoming_bandwidth = U32_MAX;

    if outgoing_bandwidth < 0 then incoming_bandwidth = 0;
    else if incoming_bandwidth > U32_MAX then incoming_bandwidth = U32_MAX;

    host.incoming_bandwidth = cast(u32)incoming_bandwidth;
    host.outgoing_bandwidth = cast(u32)outgoing_bandwidth;
    host.recalculate_bandwidth_limits = true;
}

host_channel_limit :: (host: *Host, channel_limit: int) {
    if channel_limt == 0 || channel_limit > PROTOCOL_MAX_CHANNEL_COUNT then channel_limit = PROTOCOL_MAX_CHANNEL_COUNT;

    host.channel_limit = channel_limit;
}

host_broadcast :: (host: *Host, channel_id: u8, packet: *Packet) {
    for * peer: host.peers {
        if peer.state != .CONNECTED then continue;

        peer_send(peer, channel_id, packet);
    }
    
    if packet.ref_count == 0 then packet_destroy(packet);
}

#scope_module
HOST_RECEIVE_BUFFER_SIZE          :: 256 * 1024;
HOST_SEND_BUFFER_SIZE             :: 256 * 1024;
HOST_DEFAULT_MTU                  :: 1400;
HOST_DEFAULT_MAX_PACKET_SIZE      :: 32 * 1024 * 1024;
HOST_DEFAULT_MAX_WAITING_DATA     :: 32 * 1024 * 1024;
HOST_BANDWIDTH_THROTTLE_INTERVAL  :: 1000;

host_bandwidth_throttle :: (host: *Host) {
    if host.outgoing_bandwidth == 0 && host.incoming_bandwidth == 0 then return;
 
    current_time := to_milliseconds(current_time_monotonic() - host.service_time_offset);
    elapsed_time := current_time - host.bandwidth_throttle_epoch;

    if elapsed_time < HOST_BANDWIDTH_THROTTLE_INTERVAL {
        return;
    }

    host.bandwidth_throttle_epoch = current_time;

    remaining_peers := host.connected_peers;
    if remaining_peers == 0 return;

    data_total :u32 = U32_MAX;
    bandwidth  :u32 = U32_MAX;

    if host.outgoing_bandwidth != 0 {
        data_total = 0;
        bandwidth = (host.outgoing_bandwidth * cast(u32)elapsed_time) / 1000;

        for peer: host.peers {
            if peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER continue;
            data_total += peer.outgoing_data_total;
        }
    }

    needs_adjustment := host.bandwidth_limited_peers > 0;
    throttle :u32 = 0;

    while remaining_peers > 0 && needs_adjustment {
        needs_adjustment = false;

        if data_total <= bandwidth {
            throttle = PEER_PACKET_THROTTLE_SCALE;
        } else {
            throttle = (bandwidth * PEER_PACKET_THROTTLE_SCALE) / data_total;
        }

        peer_bandwidth : u32;

        for * peer: host.peers {
            if (peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER) || peer.outgoing_bandwidth_throttle_epoch == current_time then continue;

            peer_bandwidth = (peer.incoming_bandwidth * cast(u32)elapsed_time) / 1000;
            if (throttle * peer.outgoing_data_total) / PEER_PACKET_THROTTLE_SCALE <= peer_bandwidth then continue;

            peer.packet_throttle_limit = (peer_bandwidth * PEER_PACKET_THROTTLE_SCALE) / peer.outgoing_data_total;

            if peer.packet_throttle_limit == 0 then peer.packet_throttle_limit = 1;
            if peer.packet_throttle > peer.packet_throttle_limit then peer.packet_throttle = peer.packet_throttle_limit; 

            peer.outgoing_bandwidth_throttle_epoch = current_time;

            peer.incoming_data_total = 0;
            peer.outgoing_data_total = 0;

            needs_adjustment = true;
            remaining_peers -= 1;
            bandwidth -= peer_bandwidth;
            data_total -= peer_bandwidth;
        }
    }

    if remaining_peers > 0 {
        if data_total <= bandwidth {
            throttle = PEER_PACKET_THROTTLE_SCALE;
        } else {
            throttle = (bandwidth * PEER_PACKET_THROTTLE_SCALE) / data_total;
        }

        for * peer: host.peers {
            if (peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER) || peer.outgoing_bandwidth_throttle_epoch == current_time then continue;

            peer.packet_throttle_limit = throttle;

            if peer.packet_throttle > peer.packet_throttle_limit then peer.packet_throttle = peer.packet_throttle_limit;

            peer.incoming_data_total = 0;
            peer.outgoing_data_total = 0;
        }
    }

    if host.recalculate_bandwidth_limits {
        host.recalculate_bandwidth_limits = false;

        remaining_peers = host.connected_peers;
        bandwidth = host.incoming_bandwidth;
        needs_adjustment = true;
        bandwidth_limit :u32= 0;

        if bandwidth == 0 {
            bandwidth_limit = 0;
        } else {
            while remaining_peers > 0 && needs_adjustment {
                needs_adjustment = false;
                bandwidth_limit = bandwidth / remaining_peers;

                for * peer: host.peers {
                    if (peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER) || peer.incoming_bandwidth_throttle_epoch == current_time then continue;
                    if peer.outgoing_bandwidth > 0 && peer.outgoing_bandwidth >= bandwidth_limit then continue;

                    peer.incoming_bandwidth_throttle_epoch = current_time;

                    needs_adjustment = true;
                    remaining_peers -= 1;
                    bandwidth -= peer.outgoing_bandwidth;
                }
            }
        }

        for * peer: host.peers {
            if peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER then continue;

            command : Protocol;
            command.header.command = Protocol_Command.BANDWIDTH_LIMIT | .FLAG_ACKNOWLEDGE;
            command.header.channel_id = 0xFF;
            command.bandwidth_limit.outgoing_bandwidth = host_to_net_endian_32(host.outgoing_bandwidth);

            if peer.incoming_bandwidth_throttle_epoch == current_time {
                command.bandwidth_limit.incoming_bandwidth = host_to_net_endian_32(peer.outgoing_bandwidth);
            } else {
                command.bandwidth_limit.incoming_bandwidth = host_to_net_endian_32(bandwidth_limit);
            }

            peer_queue_outgoing_command(peer, *command, null, 0, 0);
        }
    }
}

host_update_service_time :: (host: *Host) {
    host.service_time = to_milliseconds(current_time_monotonic() - host.service_time_offset);
}
