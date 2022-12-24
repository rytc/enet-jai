
Host :: struct {
    peers : [] Peer;
    connected_peers : u32;
    bandwidth_limited_peers: u32;
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
    service_time_offset : Apollo_Time;
    service_time : Apollo_Time;
    bandwidth_throttle_epoch : s64;
    recalculate_bandwidth_limits : bool;
    continue_sending : bool;
    header_flags: u32;
    commands : [PROTOCOL_MAX_PACKET_COMMANDS]Protocol;
    command_count: u32;
    buffers : [MAX_BUFFER_COUNT]Buffer;
    buffer_count : u32;
    total_sent_packets : u32;
    total_sent_data : u64;
    packet_data : [2 * PROTOCOL_MAX_MTU]u8; // 2D array in c, need to manually offset by PROTOCOL_MAX_MTU
    packet_size : u32;
    total_received_packets  : u32;
    received_data : *u8;
    received_data_length : u32;
    total_received_data_length : u32;
    dispatch_queue : List;
}

host_create :: (address: *Address, peer_count: int, channel_limit: int, incoming_bandwidth: int, outgoing_bandwidth: int) -> *Host, bool {
    host : *Host;

    if peer_count < 0 || peer_count > PROTOCOL_MAX_PEER_ID {
        log_error("Invalid peer count 0 < % < %", peer_count, PROTOCOL_MAX_PEER_ID);
        return host, false; 
    }

    // @TODO Not sure if we should actually heap allocate this? It is a big struct...
    host = New(Host);

    host.peers = NewArray(peer_count, Peer);

    host.socket = socket_create();

    if host.socket != INVALID_SOCKET set_socket_options(host.socket, .IPV6_V6ONLY, 0);

    if host.socket == INVALID_SOCKET || (socket_bind(host.socket, address) < 0 && address != null) {
        log_error("Failed to create and bind socket: %\n", WSAGetLastError());

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
    host.maximum_waiting_data = HOST_DEFAULT_MAX_WAITING_DATA; // @TODO these could probably be set on the struct?
    host.service_time_offset = current_time_monotonic();

    list_clear(*host.dispatch_queue);

    for * peer : host.peers {
        peer.host = host;
        peer.incoming_peer_id = cast(u16)(cast(u64)peer - cast(u64)host.peers.data);
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
    free(host.peers.data);
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
        channel.outgoing_reliable_seq_number = 0;
        channel.outgoing_unreliable_seq_number = 0;
        channel.incoming_reliable_seq_number = 0;
        channel.incoming_unreliable_seq_number = 0;
        channel.used_reliable_windows = 0;
        list_clear(*channel.incoming_reliable_commands);
        list_clear(*channel.incoming_unreliable_commands);
        memset(channel.reliable_windows.data, 0, PEER_RELIABLE_WINDOWS * size_of(type_of(PEER_RELIABLE_WINDOWS)));
    }

    command : Protocol;
    command.header.command                     = cast(u8)(PROTOCOL_COMMAND_CONNECT | PROTOCOL_FLAG_ACKNOWLEDGE);
    command.header.channel_id                   = 0xFF;
    command.connect.outgoing_peer_id             = host_to_net_endian(current_peer.incoming_peer_id);
    command.connect.incoming_session_id          = current_peer.incoming_session_id;
    command.connect.outgoing_session_id          = current_peer.outgoing_session_id;
    command.connect.mtu                        = host_to_net_endian(current_peer.mtu);
    command.connect.window_size                 = host_to_net_endian(current_peer.window_size);
    command.connect.channel_count               = host_to_net_endian(cast(u32)channel_count);
    command.connect.incoming_bandwidth          = host_to_net_endian(cast(u32)host.incoming_bandwidth);
    command.connect.outgoing_bandwidth          = host_to_net_endian(cast(u32)host.outgoing_bandwidth);
    command.connect.packet_throttle_interval     = host_to_net_endian(current_peer.packet_throttle_interval);
    command.connect.packet_throttle_acceleration = host_to_net_endian(current_peer.packet_throttle_acceleration);
    command.connect.packet_throttle_deceleration = host_to_net_endian(current_peer.packet_throttle_deceleration);
    command.connect.connect_id                  = current_peer.connect_id;
    command.connect.data                       = host_to_net_endian(data);

    peer_queue_outgoing_command(current_peer, *command, null, 0, 0);

    return current_peer;
}

// Intended to be called within a loop
// If it's inside a game loop or event loop, then it should be called in that loop
// for best performance
host_service :: (host: *Host, event: *Event, timeout: s64) -> int {
    wait_condition : Socket_Wait;

    if event {
        event.type = .NONE;
        event.peer = null;
        event.packet = null;

        dispatch_result := protocol_dispatch_incoming_commands(host, event);
        if dispatch_result == {
            case 1; 
                return 1;
            case -1;
                log_error("Error dispatching incoming packets\n");
                return -1;
        }
    }

    host.service_time = current_time_monotonic() - host.service_time_offset;
    service_time := to_milliseconds(host.service_time);
    timeout += service_time;

    while true {
        if service_time - host.bandwidth_throttle_epoch > HOST_BANDWIDTH_THROTTLE_INTERVAL then host_bandwidth_throttle(host);

        send_outgoing :: () -> int #expand {
            send_out_status := protocol_send_outgoing_commands(`host, `event, true);
            if send_out_status == {
                case 1;
                    `return 1;
                case -1;
                    log_error("Error sending outgoing packets\n");
                    `return -1;
            }
        }

        send_outgoing(); 

        receive_in_status := protocol_receive_incoming_commands(host, event);
        if receive_in_status == {
            case 1;
                return 1;
            case -1;
                log_error("Error receiving incoming packets\n");
                return -1;
        }

        send_outgoing();

        dispatch_incoming_status := protocol_dispatch_incoming_commands(host, event);
        if dispatch_incoming_status == {
            case 1;
                return 1;
            case -1;
                log_error("Error dispatching incoming commands\n");
                return -1;
        }

        if service_time >= timeout then return 0; 

        while true {
            host.service_time = current_time_monotonic() - host.service_time_offset;
            service_time = to_milliseconds(host.service_time);
            if service_time > timeout then return 0;

            wait_condition = Socket_Wait.RECEIVE & .INTERRUPT;
            if socket_wait(host.socket, *wait_condition, service_time - timeout) != 0 {
                return -1;
            }

            if !(wait_condition & .INTERRUPT) then break;
        }

        if !(wait_condition & .RECEIVE) break;
    }

    return 0;

}

host_send_raw :: (host: *Host, address: *Address, data: []u8) {
    buffer : [1]Buffer;
    buffer[0].data = data.data;
    buffer[0].length = data.count;
    socket_send(host.socket, address, buffer);
}

host_send_raw :: (host: *Host, address: *Address, data: *$T) {
    buffer : [1]Buffer;
    buffer[0].data = data;
    buffer[0].length = size_of(t);
    socket_send(host.socket, address, buffer);
}

#scope_module

host_bandwidth_throttle :: (host: *Host) {
    current_time := current_time_monotonic();
    current_time_ms := to_milliseconds(current_time);
    elapsed_time := current_time_ms - host.bandwidth_throttle_epoch;
    remaining_peers := host.connected_peers;
    data_total :u32 = U32_MAX;
    bandwidth  :u32 = U32_MAX;
    throttle   :u32 = 0;
    bandwidth_limit :u32= 0;

    needs_adjustment := host.bandwidth_limited_peers > 0;

    if elapsed_time < HOST_BANDWIDTH_THROTTLE_INTERVAL return;
    if host.outgoing_bandwidth == 0 && host.incoming_bandwidth == 0 return;

    host.bandwidth_throttle_epoch = current_time_ms;

    if remaining_peers == 0 return;

    if host.outgoing_bandwidth != 0 {
        data_total = 0;
        bandwidth = (host.outgoing_bandwidth * cast(u32)elapsed_time) / 1000;

        for peer: host.peers {
            if peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER continue;
            data_total += peer.outgoing_data_total;
        }
    }


    while remaining_peers > 0 && needs_adjustment {
        needs_adjustment = false;

        if data_total <= bandwidth {
            throttle = PEER_PACKET_THROTTLE_SCALE;
        } else {
            throttle = (bandwidth * PEER_PACKET_THROTTLE_SCALE) / data_total;
        }

        peer_bandwidth : u32;

        for * peer: host.peers {
            if (peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER) || peer.incoming_bandwidth == 0 || peer.outgoing_bandwidth_throttle_epoch == current_time_ms then continue;

            peer_bandwidth = (peer.incoming_bandwidth * cast(u32)elapsed_time) / 1000;
            if (throttle * peer.outgoing_data_total) / PEER_PACKET_THROTTLE_SCALE <= peer_bandwidth then continue;

            peer.packet_throttle_limit = (peer_bandwidth * PEER_PACKET_THROTTLE_SCALE) / peer.outgoing_data_total;

            if peer.packet_throttle_limit == 0 then peer.packet_throttle_limit = 1;
            if peer.packet_throttle > peer.packet_throttle_limit then peer.packet_throttle = peer.packet_throttle_limit; 

            peer.outgoing_bandwidth_throttle_epoch = current_time_ms;

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
            if (peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER) || peer.outgoing_bandwidth_throttle_epoch == current_time_ms then continue;

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

        if bandwidth == 0 {
            bandwidth_limit = 0;
        } else {
            while remaining_peers > 0 && needs_adjustment {
                needs_adjustment = false;
                bandwidth_limit = bandwidth / remaining_peers;

                for * peer: host.peers {
                    if (peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER) || peer.incoming_bandwidth_throttle_epoch == current_time_ms then continue;
                    if peer.outgoing_bandwidth > 0 && peer.outgoing_bandwidth >= bandwidth_limit then continue;

                    peer.incoming_bandwidth_throttle_epoch = current_time_ms;

                    needs_adjustment = true;
                    remaining_peers -= 1;
                    bandwidth -= peer.outgoing_bandwidth;
                }
            }
        }

        for * peer: host.peers {
            if peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER then continue;

            command : Protocol;
            command.header.command = cast(u8)(PROTOCOL_COMMAND_BANDWIDTH_LIMIT | PROTOCOL_FLAG_ACKNOWLEDGE);
            command.header.channel_id = 0xFF;
            command.bandwidth_limit.outgoing_bandwidth = host_to_net_endian(host.outgoing_bandwidth);

            if peer.incoming_bandwidth_throttle_epoch == current_time_ms {
                command.bandwidth_limit.incoming_bandwidth = host_to_net_endian(peer.outgoing_bandwidth);
            } else {
                command.bandwidth_limit.incoming_bandwidth = host_to_net_endian(bandwidth_limit);
            }

            peer_queue_outgoing_command(peer, *command, null, 0, 0);
        }
    }
}



#scope_file

HOST_RECEIVE_BUFFER_SIZE          :: 256 * 1024;
HOST_SEND_BUFFER_SIZE             :: 256 * 1024;
HOST_DEFAULT_MTU                  :: 1400;
HOST_DEFAULT_MAX_PACKET_SIZE  :: 32 * 1024 * 1024;
HOST_DEFAULT_MAX_WAITING_DATA :: 32 * 1024 * 1024;
HOST_BANDWIDTH_THROTTLE_INTERVAL  :: 1000;

