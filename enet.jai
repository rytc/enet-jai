HOST_ANY :: V6_ANY_ADDR;

Event_Type :: enum {
    NONE;
    CONNECT;
    DISCONNECT;
    RECEIVE;
    DISCONNECT_TIMEOUT;
}

Packet_Flags :: enum_flags u16 {
    RELIABLE;
    UNSEQUENCED;
    NO_ALLOCATE;
    UNRELIABLE_FRAGMENT;
    SENT;
}

Address :: struct {
    host: in6_addr;
    port: u16;
    sin6_scope_id: u16;
}

Packet :: struct {
    ref_count:    s32;
    flags:        Packet_Flags;
    data:         *u8;
    data_length:  u32;
    user_data:    *Any;
}

Event :: struct {
    type:        Event_Type;
    peer:        *Peer;
    channel_id:  u8;
    data:        u32;
    packet:      *Packet;
}

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

    buffers:      [MAX_BUFFER_COUNT]Buffer;
    buffer_count: u32;

    total_sent_packets:     u32;
    total_sent_data:        u64;
    maximum_packet_size:    u32;
    packet_data:            [2 * PROTOCOL_MAX_MTU]u8; // 2D array in C. Index [1] is used for compression which is TODO
    packet_size:            u32;
    total_received_packets: u32;

    received_data:              *u8;
    received_data_length:       u32;
    total_received_data_length: u32;
    maximum_waiting_data:       u32;

    continue_sending: bool;
    dispatch_queue:   List;
}

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
    #as using dispatch_list: List_Node;

    state:      Peer_State;
    channels:   []Channel;
    address:    Address;
    connect_id: u32;
    data:       *void;
    mtu:        u32;
    host:       *Host;

    window_size: u32;

    outgoing_peer_id: u16;
    incoming_peer_id: u16;

    outgoing_session_id: u8; 
    incoming_session_id: u8;

    outgoing_data_total: u32;
    incoming_data_total: u32;

    outgoing_bandwidth: u32;
    incoming_bandwidth: u32;
    outgoing_bandwidth_throttle_epoch: s64; // :Time
    incoming_bandwidth_throttle_epoch: s64; // :Time

    packet_throttle:              u32;
    packet_throttle_limit:        u32;
    packet_throttle_interval:     u32;
    packet_throttle_acceleration: u32;
    packet_throttle_deceleration: u32;
    packet_throttle_epoch:        s64; // :Time
    packet_throttle_counter:      u32;

    outgoing_reliable_seq_number: u16;
    outgoing_unsequenced_group:   u16;
    unsequenced_window:           [PEER_UNSEQUENCED_WINDOW_SIZE / 32]u32;
    incoming_unsequenced_group:   u16;

    outgoing_reliable_commands:    List;
    outgoing_unreliable_commands:  List;
    acknowledgements:              List;
    sent_reliable_commands:        List;
    sent_unreliable_commands:      List;
    dispatched_commands:           List;

    next_timeout:       s64; // :Time
    last_received_time: s64; // :Time
    last_sent_time:     s64; // :Time
    ping_interval:      s64; // :Time
    packet_loss_epoch:  s64; // :Time

    packets_sent:         u32;
    packets_lost:         u32;
    packet_loss:          u32;
    packet_loss_variance: u32;

    total_data_sent:          u64;
    total_data_received:      u64;
    total_packets_lost:       u32;
    total_packets_sent:       u32;
    total_waiting_data:       u32;
    reliable_data_in_transit: u32;
    
    earliest_timeout:                 s64; // :Time
    timeout_minimum:                  s64; // :Time
    timeout_maximum:                  s64; // :Time
    timeout_limit:                    s64; // :Time
    round_trip_time:                  s64; // :Time
    round_trip_timeout:               s64; // :Time
    round_trip_time_variance:         s64; // :Time
    lowest_round_trip_time_variance:  s64; // :Time
    highest_round_trip_time_variance: s64; // :Time
    last_round_trip_time_variance:    s64; // :Time
    last_round_trip_time:             s64; // :Time
    lowest_round_trip_time:           s64; // :Time

    needs_dispatch: bool;
    event_data:     u32;
}

initialize :: () -> bool {
    #if OS == .WINDOWS {
        version :u16= (1 << 8) | 1;
        wsa_data : WSAData;

        if WSAStartup(version, *wsa_data) {
            log_error("Failed to initialize enet: Failed to startup WSA");
            return false;
        }

        if wsa_data.wVersion & 1 != 1 || wsa_data.wVersion >> 8 != 1 {
            log_error("Failed to initialize enet: Requested WSA version is % but got %", version, wsa_data.wVersion);
            WSACleanup();
            return false;
        }
    }

    start_time = current_time_monotonic();

    // No initialization needed for unix

    return true;
}

deinitialize :: () {
    #if OS == .WINDOWS {
        WSACleanup();
    }

    // No deinitialization needed for unix
}

packet_create :: (data: *$T, flags: Packet_Flags = .RELIABLE) -> *Packet #expand {
    return packet_create(cast(*u8)data, size_of(T), flags);
}

packet_create :: (data: []u8, flags: Packet_Flags = .RELIABLE) -> *Packet #expand {
    return packet_create(cast(*u8)data.data, data.count, flags);
}

packet_create :: (data: *u8, data_length: int, flags: Packet_Flags = .RELIABLE) -> *Packet {
    packet: *Packet;

    assert(data_length >= 0 && data_length <= U32_MAX);

    if flags & .NO_ALLOCATE {
        packet = New(Packet);
        packet.data = xx data;
    } else {
        packet = alloc(size_of(Packet) + data_length);
        packet.data = cast(*u8)(packet) + size_of(Packet);

        if data {
            memcpy(packet.data, data, cast(u32)data_length);
        }
    }

    packet.flags = flags;
    packet.data_length = cast(u32)data_length;
    packet.ref_count = 0;

    return packet;
}

packet_destroy :: (packet: *Packet) {
    free(packet);
}

get_host_ip_address :: (host: string) -> Address, bool {
    address, success := lookup_host(host, true);
    return address, success;
}

get_host_name_address :: (host: string) -> Address, bool {
    address, success := lookup_host(host, false);
    return address, success;
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
        array_reset(*host.peers);
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
        array_reset(*peer.channels);
    }
    array_reset(*host.peers);
    free(host);
}

host_connect :: (host: *Host, address: Address, channel_count: int, data: u32) -> *Peer {
    current_peer: *Peer;

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
                    log_error("Error sending outgoing packets");
                    `return .ERROR;
            }
        }

        send_outgoing(); 

        receive_in_status := protocol_receive_incoming_commands(host, event);
        if receive_in_status == {
            case .SUCCESS; 
                return .SUCCESS;
            case .ERROR;
                log_error("Error receiving incoming packets");
                return .ERROR;
        }

        send_outgoing();

        if event {
            dispatch_incoming_status := protocol_dispatch_incoming_commands(host, event);
            if dispatch_incoming_status == {
                case .SUCCESS; 
                    return .SUCCESS;
                case .ERROR;
                    log_error("Error dispatching incoming commands");
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
    buffer[0].length = xx data.count;
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
    if channel_limit == 0 || channel_limit > PROTOCOL_MAX_CHANNEL_COUNT then channel_limit = PROTOCOL_MAX_CHANNEL_COUNT;

    host.channel_limit = cast(u32)channel_limit;
}

host_broadcast :: (host: *Host, channel_id: u8, packet: *Packet) {
    for * peer: host.peers {
        if peer.state != .CONNECTED then continue;

        peer_send(peer, channel_id, packet);
    }
    
    if packet.ref_count == 0 then packet_destroy(packet);
}

peer_send :: (peer: *Peer, channel_id: int, packet: *Packet) -> Result_Status {
    assert(channel_id >= 0 && channel_id < PROTOCOL_MAX_CHANNEL_COUNT);

    channel := *peer.channels[channel_id];

    if peer.state != .CONNECTED || channel_id >= peer.channels.count || packet.data_length > peer.host.maximum_packet_size then return -1;

    fragment_length :u16= cast(u16)(peer.mtu - size_of(Protocol_Header) - size_of(Protocol_Send_Fragment));

    // @TODO implement checksum
    //if peer.host.checksum

    if packet.data_length > fragment_length {
        fragment_count := (packet.data_length + fragment_length - 1) / fragment_length;

        if fragment_count > PROTOCOL_MAX_FRAGMENT_COUNT return .ERROR;

        command_number: Protocol_Command;
        start_seq_number: u16;

        if packet.flags & (Packet_Flags.RELIABLE | .UNRELIABLE_FRAGMENT) == Packet_Flags.UNRELIABLE_FRAGMENT && 
            channel.outgoing_unreliable_seq_number < 0xFFFF {

            command_number = .SEND_UNRELIABLE_FRAGMENT;
            start_seq_number = host_to_net_endian_16(channel.outgoing_unreliable_seq_number + 1);
        } else {
            command_number = .SEND_FRAGMENT_ACKNOWLEDGE;
            start_seq_number = host_to_net_endian_16(channel.outgoing_reliable_seq_number + 1);
        }

        fragments: List;

        list_clear(*fragments);

        fragment_offset :u32= 0;
        fragment_number :u32= 0;

        while fragment_offset < packet.data_length {
            if packet.data_length - fragment_offset < fragment_length {
                fragment_length = cast(u16)(packet.data_length - fragment_offset);
            }

            fragment := New(Outgoing_Command);

            // @TODO handle alloc failure

            fragment.fragment_offset = fragment_offset;
            fragment.fragment_length = fragment_length;
            fragment.packet = packet;
            fragment.command.header.command = command_number;
            fragment.command.header.channel_id = cast(u8)channel_id;

            fragment.command.send_fragment.start_seq_number = start_seq_number;

            fragment.command.send_fragment.data_length = host_to_net_endian_16(fragment_length);
            fragment.command.send_fragment.fragment_count = host_to_net_endian_32(fragment_count);
            fragment.command.send_fragment.fragment_number = host_to_net_endian_32(fragment_number);
            fragment.command.send_fragment.total_length = host_to_net_endian_32(packet.data_length);
            fragment.command.send_fragment.fragment_offset = host_to_net_endian_32(fragment_offset);
            
            list_insert(list_end(*fragments), fragment);

            fragment_offset += fragment_length;
            fragment_number += 1;
        }

        packet.ref_count += cast(s32)fragment_number;

        while !list_empty(*fragments) {
            fragment := cast(*Outgoing_Command)list_remove(list_begin(*fragments));
            peer_setup_outgoing_command(peer, fragment);
        }

        return .NONE;
    }

    command: Protocol;

    command.header.channel_id = cast(u8)channel_id;

    if packet.flags & (Packet_Flags.RELIABLE | .UNSEQUENCED) == .UNSEQUENCED {
        command.header.command = Protocol_Command.SEND_UNSEQUENCED | .FLAG_UNSEQUENCED;
        command.send_unsequenced.data_length = host_to_net_endian_16(cast(u16)packet.data_length);
    } else if packet.flags & Packet_Flags.RELIABLE || channel.outgoing_unreliable_seq_number >= 0xFFFF {
        command.header.command = .SEND_RELIABLE_ACKNOWLEDGE;
        command.send_reliable.data_length = host_to_net_endian_16(cast(u16)packet.data_length);
    } else {
        command.header.command = .SEND_UNRELIABLE;
        command.send_unreliable.data_length = host_to_net_endian_16(cast(u16)packet.data_length);
    }
    
    if packet.flags & Packet_Flags.RELIABLE {
        print("Sending reliable %\n", command.header.command);
    }

    if peer_queue_outgoing_command(peer, *command, packet, 0, xx packet.data_length) == null then return .ERROR;

    return .NONE;
}

peer_disconnect :: (peer: *Peer, data: u32) {
    if peer.state == .DISCONNECTING || peer.state == .DISCONNECTED ||
       peer.state == .ACKNOWLEDGING_DISCONNECT || peer.state == .ZOMBIE then return;

    peer_reset_queues(peer);
    
    command: Protocol;
    command.header.command = .DISCONNECT;
    command.header.channel_id = 0xFF;
    command.disconnect.data = host_to_net_endian_32(data);

    if peer.state == .CONNECTED || peer.state == .DISCONNECT_LATER {
        command.header.command |= Protocol_Command.FLAG_ACKNOWLEDGE;
    } else {
        command.header.command |= Protocol_Command.FLAG_UNSEQUENCED;
    }

    peer_queue_outgoing_command(peer, *command, null, 0, 0);

    if peer.state == .CONNECTED || peer.state == .DISCONNECT_LATER {
        peer_on_disconnect(peer);
        peer.state = .DISCONNECTING;
    } else {
        host_flush(peer.host);
        peer_reset(peer);
    }
}

peer_disconnect_now :: (peer: *Peer, data: u32) {
    if peer.state == .DISCONNECTED return;

    if peer.state != .ZOMBIE || peer.state != .DISCONNECTING {
        peer_reset_queues(peer);

        command: Protocol;
        command.header.command = Protocol_Command.DISCONNECT | .FLAG_UNSEQUENCED;
        command.header.channel_id = 0xFF;
        command.disconnect.data = host_to_net_endian_32(data);
        
        peer_queue_outgoing_command(peer, *command, null, 0, 0);
        host_flush(peer.host);
    }

    peer_reset(peer);
}

peer_disconnect_later :: (peer: *Peer, data: u32) {
    if peer.state == .CONNECTED || peer.state == .DISCONNECT_LATER &&
       (!list_empty(*peer.outgoing_reliable_commands) &&
        list_empty(*peer.outgoing_unreliable_commands) &&
        list_empty(*peer.sent_reliable_commands)) {

        peer.state = .DISCONNECT_LATER;
        peer.event_data = data;
    } else {
        peer_disconnect(peer, data);
    }
}

peer_ping :: (peer: *Peer) {
    command: Protocol;

    if peer.state != .CONNECTED return;

    command.header.command = Protocol_Command.PING | .FLAG_ACKNOWLEDGE;
    command.header.channel_id = 0xFF;

    print("Sending ping\n");

    peer_queue_outgoing_command(peer, *command, null, 0, 0);
}

peer_ping_interval :: (peer: *Peer, interval: u32) {
    peer.ping_interval = ifx interval then interval else PEER_PING_INTERVAL;
}

peer_timeout :: (peer: *Peer, timeout_limit: u32, timeout_min: u32, timeout_max: u32) {
    peer.timeout_limit = ifx timeout_limit > 0 then timeout_limit else PEER_TIMEOUT_LIMIT;
    peer.timeout_minimum = ifx timeout_min > 0 then timeout_min else PEER_TIMEOUT_MINIMUM;
    peer.timeout_maximum = ifx timeout_max > 0 then timeout_max else PEER_TIMEOUT_MAXIMUM;
}

peer_reset :: (peer: *Peer) {
    peer_on_disconnect(peer);

    // Hold onto the following data e.g., so they can be used when the disconnect event is sent
    peer.* = Peer.{
        connect_id          = peer.connect_id,
        address             = peer.address,
        host                = peer.host,
        mtu                 = peer.host.mtu,
        data                = peer.data,
        incoming_peer_id    = peer.incoming_peer_id,
        outgoing_session_id = 0xFF,
        incoming_session_id = 0xFF,
        // These are used in peer_reset_queues below
        channels            = peer.channels,
        needs_dispatch      = peer.needs_dispatch
    };

    peer.state                        = .DISCONNECTED;
    peer.outgoing_peer_id             = PROTOCOL_MAX_PEER_ID;
    peer.timeout_limit                = PEER_TIMEOUT_LIMIT;
    peer.timeout_minimum              = PEER_TIMEOUT_MINIMUM;
    peer.timeout_maximum              = PEER_TIMEOUT_MAXIMUM;
    peer.last_round_trip_time         = PEER_DEFAULT_ROUND_TRIP_TIME;
    peer.lowest_round_trip_time       = PEER_DEFAULT_ROUND_TRIP_TIME;
    peer.round_trip_time              = PEER_DEFAULT_ROUND_TRIP_TIME;
    peer.ping_interval                = PEER_PING_INTERVAL;
    peer.packet_throttle              = PEER_DEFAULT_PACKET_THROTTLE;
    peer.packet_throttle_limit        = PEER_PACKET_THROTTLE_SCALE;
    peer.packet_throttle_acceleration = PEER_PACKET_THROTTLE_ACCELERATION;
    peer.packet_throttle_deceleration = PEER_PACKET_THROTTLE_DECELERATION;
    peer.packet_throttle_interval     = PEER_PACKET_THROTTLE_INTERVAL;
    peer.window_size                  = PROTOCOL_MAX_WINDOW_SIZE;

    list_clear(*peer.outgoing_reliable_commands);
    list_clear(*peer.outgoing_unreliable_commands);
    list_clear(*peer.sent_reliable_commands);
    list_clear(*peer.sent_unreliable_commands);
    list_clear(*peer.acknowledgements);
    list_clear(*peer.dispatched_commands);

    peer_reset_queues(peer);
}

peer_reset_queues :: (peer: *Peer) {
    if peer.needs_dispatch {
        list_remove(peer);
        peer.needs_dispatch = false;
    }

    while !list_empty(*peer.acknowledgements) {
        free(list_remove(list_begin(*peer.acknowledgements)));
    }

    peer_reset_outgoing_commands(*peer.sent_reliable_commands);
    peer_reset_outgoing_commands(*peer.sent_unreliable_commands);
    peer_reset_outgoing_commands(*peer.outgoing_reliable_commands);
    peer_reset_outgoing_commands(*peer.outgoing_unreliable_commands);
    peer_reset_incoming_commands(*peer.dispatched_commands);

    if peer.channels.count > 0 {
        for *channel: peer.channels {
            peer_reset_incoming_commands(*channel.incoming_reliable_commands);
            peer_reset_incoming_commands(*channel.incoming_unreliable_commands);
        }

        array_reset(*peer.channels);
    }
}

peer_reset_outgoing_commands :: (list: *List) {
    while !list_empty(list) {
        outgoing_cmd := cast(*Outgoing_Command)list_remove(list_begin(list));
        
        if outgoing_cmd.packet {
            outgoing_cmd.packet.ref_count -= 1;
            if outgoing_cmd.packet.ref_count == 0 packet_destroy(outgoing_cmd.packet);
        }

        free(outgoing_cmd);
    }
}

peer_reset_incoming_commands :: (list: *List) {
    peer_remove_incoming_commands(list, list_begin(list), list_end(list));
}



#scope_file
#import "Math"; // U32_MAX
#import "Basic";
#import "Socket";

#if OS == .WINDOWS {
    Windows :: #import "Windows"; // timeGetTime
}

HOST_RECEIVE_BUFFER_SIZE          :: 256 * 1024;
HOST_SEND_BUFFER_SIZE             :: 256 * 1024;
HOST_DEFAULT_MTU                  :: 1400;
HOST_DEFAULT_MAX_PACKET_SIZE      :: 32 * 1024 * 1024;
HOST_DEFAULT_MAX_WAITING_DATA     :: 32 * 1024 * 1024;
HOST_BANDWIDTH_THROTTLE_INTERVAL  :: 1000;

PEER_WINDOW_SIZE_SCALE            :: 64 * 1024;
PEER_RELIABLE_WINDOWS          :u16: 16;
PEER_RELIABLE_WINDOW_SIZE         :: 0x1000;
PEER_DEFAULT_PACKET_THROTTLE      :: 32;
PEER_PACKET_THROTTLE_SCALE        :: 32;
PEER_PACKET_THROTTLE_ACCELERATION :: 2;
PEER_PACKET_THROTTLE_DECELERATION :: 2;
PEER_PACKET_THROTTLE_INTERVAL     :: 5000;
PEER_PACKET_LOSS_INTERVAL         :: 10000;
PEER_PACKET_LOSS_SCALE            :: (1 << 16);
PEER_FREE_RELIABLE_WINDOWS        :: 8;
PEER_TIMEOUT_LIMIT                :: 32;
PEER_TIMEOUT_MINIMUM              :: 5000;
PEER_TIMEOUT_MAXIMUM              :: 30000;
PEER_DEFAULT_ROUND_TRIP_TIME      :: 500;
PEER_PING_INTERVAL                :: 500;
PEER_PACKET_THROTTLE_COUNTER      :: 7;
PEER_UNSEQUENCED_WINDOW_SIZE      :: 1024;
PEER_UNSEQUENCED_WINDOWS          :: 64;
PEER_FREE_UNSEQUENCED_WINDOWS     :: 32;

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
PROTOCOL_COMMAND_COUNT       :: 13;

DUMMY_COMMAND: Incoming_Command; 

start_time : Apollo_Time;

V6_ANY_ADDR :: in6_addr.{.{.[ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ]}};
V6_NO_ADDR  :: in6_addr.{.{.[ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff ]}};

#if OS == .WINDOWS {
    MAX_BUFFER_COUNT :s32: cast(s32)MSG.MSG_MAXIOVLEN;
} else {
    MAX_BUFFER_COUNT :: 1 + 2 * PROTOCOL_MAX_PACKET_COMMANDS; 
}

Result_Status :: enum {
    NONE;
    SUCCESS;
    ERROR;
    FAILURE;
}

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

Channel :: struct {
    used_reliable_windows: type_of(PEER_RELIABLE_WINDOWS); 
    reliable_windows:      [PEER_RELIABLE_WINDOWS] u16;

    outgoing_reliable_seq_number:   u16;
    outgoing_unreliable_seq_number: u16;

    incoming_reliable_seq_number: u16;
    incoming_reliable_commands:   List;

    incoming_unreliable_seq_number: u16;
    incoming_unreliable_commands:   List;
}

// Should match WSABUF
Buffer :: struct {
    length: u32;
    data:   *u8;
}

Acknowledgement :: struct {
    #as using list: List_Node;
    sent_time:      u16; // :Time
    command:        Protocol;
}

Command :: struct {
    #as using list:  List_Node;
    packet:         *Packet;
}

Incoming_Command :: struct {
    #as using base:         Command;
    reliable_seq_number:    u16;
    unreliable_seq_number:  u16;
    command:                Protocol;
    fragment_count:         u32;
    fragments_remaining:    u32;
    fragments:              []u32;
}

Outgoing_Command :: struct {
    #as using base           : Command;
    reliable_seq_number      : u16;
    unreliable_seq_number    : u16;
    sent_time                : s64;
    round_trip_timeout       : s64;
    round_trip_timeout_limit : s64;
    fragment_offset          : u32;
    fragment_length          : u16;
    send_attempts            : u16;
    command                  : Protocol;
}

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
    peer_id:   u16;
    sent_time: u16;
}

Protocol_Command_Header :: struct {
    command:             Protocol_Command;
    channel_id:          u8;
    reliable_seq_number: u16;
}

Protocol_Acknowledge :: struct {
    using header: Protocol_Command_Header;

    received_reliable_seq_number: u16;
    received_sent_time:           u16;
}

Protocol_Connect :: struct {
    using header: Protocol_Command_Header;

    outgoing_peer_id:    u16;
    incoming_session_id: u8;
    outgoing_session_id: u8;
    
    mtu:            u32;
    window_size:    u32;
    channel_count:  u32;

    incoming_bandwidth: u32;
    outgoing_bandwidth: u32;

    packet_throttle_interval:     u32;
    packet_throttle_acceleration: u32;
    packet_throttle_deceleration: u32;
    
    connect_id: u32;
    data:       u32;
}

Protocol_Verify_Connect :: struct {
    using header: Protocol_Command_Header;

    outgoing_peer_id:    u16;
    incoming_session_id: u8;
    outgoing_session_id: u8;

    mtu:           u32;
    window_size:   u32;
    channel_count: u32;

    incoming_bandwidth: u32;
    outgoing_bandwidth: u32;

    packet_throttle_interval:     u32;
    packet_throttle_acceleration: u32;
    packet_throttle_deceleration: u32;

    connect_id: u32;
}

Protocol_Disconnect :: struct {
    using header: Protocol_Command_Header;
    data: u32;
}

Protocol_Ping :: struct {
    using header: Protocol_Command_Header;
}

Protocol_Send_Reliable :: struct {
    using header: Protocol_Command_Header;
    data_length:  u16;
}

Protocol_Send_Unreliable :: struct {
    using header: Protocol_Command_Header;

    unreliable_seq_number: u16;
    data_length:           u16;
}

Protocol_Send_Fragment :: struct {
    using header: Protocol_Command_Header;

    start_seq_number: u16;
    data_length:      u16;
    fragment_count:   u32;
    fragment_number:  u32;
    total_length:     u32;
    fragment_offset:  u32;
}

Protocol_Send_Unsequenced :: struct {
    using header: Protocol_Command_Header;

    unsequenced_group: u16;
    data_length:       u16;
}

Protocol_Bandwidth_Limit :: struct {
    using header: Protocol_Command_Header;

    incoming_bandwidth: u32;
    outgoing_bandwidth: u32;
}

Protocol_Throttle_Configure :: struct {
    using header: Protocol_Command_Header;

    packet_throttle_interval:     u32;
    packet_throttle_acceleration: u32;
    packet_throttle_deceleration: u32;
}


Protocol :: union {
    header:             Protocol_Command_Header;
    acknowledge:        Protocol_Acknowledge;
    connect:            Protocol_Connect;
    verify_connect:     Protocol_Verify_Connect;
    disconnect:         Protocol_Disconnect;
    ping:               Protocol_Ping;
    send_reliable:      Protocol_Send_Reliable;
    send_unreliable:    Protocol_Send_Unreliable;
    send_unsequenced:   Protocol_Send_Unsequenced;
    send_fragment:      Protocol_Send_Fragment;
    bandwidth_limit:    Protocol_Bandwidth_Limit;
    throttle_configure: Protocol_Throttle_Configure;
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



List_Node :: struct {
    prev: *List_Node;
    next: *List_Node;
}

List :: struct {
    sentinel : List_Node;
}

random_seed :: () -> u64 {
    #if OS == .WINDOWS {
        return cast(u64)Windows.timeGetTime();
    } else {
        return cast(u64)time(null);
    }
}

lookup_host :: (name: string, no_dns: bool) -> Address, bool {
    result_list: *addrinfo;
    result_address: Address;

    hints: addrinfo;
    hints.ai_family = AF_UNSPEC;

    if no_dns hints.ai_flags = .NUMERICHOST;

    hostname := temp_c_string(name);

    defer freeaddrinfo(result_list);
    if getaddrinfo(hostname, null, *hints, *result_list) != 0 {
        return result_address, false;
    }

    result := result_list;
    while result != null {
        defer result += 1;

        if result.ai_addr != null {
            if result.ai_family == AF_INET || (result.ai_family == AF_UNSPEC && result.ai_addrlen == size_of(sockaddr_in)) {
                sock_addr : *sockaddr_in = cast(*sockaddr_in)result.ai_addr;
                result_address.host = map_ip4_to_ip6(sock_addr.sin_addr);
                result_address.sin6_scope_id = 0;
                return result_address, true;
            } else if result.ai_family == AF_INET6 || (result.ai_family == AF_UNSPEC && result.ai_addrlen == size_of(sockaddr_in6)) {
                sock_addr : sockaddr_in6 = cast(*sockaddr_in6)result.ai_addr;
                result_address.host = sock_addr.sin6_addr;
                result_address.sin6_scope_id = xx sock_addr.sin6_scope_id;
                return result_address, true;
            }
        }
    }

    return result_address, false;
}

map_ip4_to_ip6 :: (addr: in_addr) -> in6_addr {

    if addr.S_un.S_addr == 0x00000000 {
        return xx V6_ANY_ADDR;
    } else if addr.S_un.S_addr == 0xFFFFFFFF {
        return xx V6_NO_ADDR; 
    }

    result: in6_addr;
    result.u.Byte[10] = 0xFF;
    result.u.Byte[11] = 0xFF;
    result.u.Byte[12] = addr.S_un.S_un_b.s_b1;
    result.u.Byte[13] = addr.S_un.S_un_b.s_b2;
    result.u.Byte[14] = addr.S_un.S_un_b.s_b3;
    result.u.Byte[15] = addr.S_un.S_un_b.s_b4;

    return result;
}

map_ip6_to_ip4 :: (addr: in6_addr) -> in_addr {
    result: in_addr;
    result.S_un.S_un_b.s_b1 = addr.u.Byte[12];
    result.S_un.S_un_b.s_b2 = addr.u.Byte[13];
    result.S_un.S_un_b.s_b3 = addr.u.Byte[14];
    result.S_un.S_un_b.s_b4 = addr.u.Byte[15];

    return result;
}

host_to_net_endian_16 :: inline (value: u16 ) -> u16 {
    return htons(value);
}

host_to_net_endian_32 :: inline (value: u32) -> u32 {
    return htonl(value);
}

net_to_host_endian_16 :: inline (value: u16) -> u16 {
    return ntohs(value);
}

net_to_host_endian_32 :: inline (value: u32) -> u32 {
    return ntohl(value);
}

in6_equal :: inline (a: in6_addr, b: in6_addr) -> bool {
    return memcmp(*a, *b, size_of(in6_addr)) == 0;
}

time_difference :: inline (a: s64, b: s64) -> s64 {
    return max(a,b) - min(a,b);
}

channel_reset :: (using channel: *Channel) {
    outgoing_reliable_seq_number   = 0;
    outgoing_unreliable_seq_number = 0;
    incoming_reliable_seq_number   = 0;
    incoming_unreliable_seq_number = 0;
    used_reliable_windows          = 0;
    list_clear(*incoming_reliable_commands);
    list_clear(*incoming_unreliable_commands);
    memset(reliable_windows.data, 0, PEER_RELIABLE_WINDOWS * size_of(u16));
}

socket_create :: () -> Socket {
    return socket(PF_INET6, .DGRAM, 0);
}

socket_destroy :: (socket: Socket) {
    #if OS == .WINDOWS {
        closesocket(socket);
    } else #if OS == .UNIX {
        close(socket);
    }
}

set_socket_options :: (socket: Socket, options: Socket_Options, value: s32) -> bool {
    result: int;

    if options == {
        case .NONEBLOCK;
            #if OS == .WINDOWS {
                result = ioctlsocket(socket, FIONBIO, cast(*u32)*value);
            } else {
                other := fcntl(socket, F_GETFL) & ~O_NONBLOCK;
                result = fcntl(socket, F_SETFL, (ifx value then O_NONBLOCK else 0) | other);
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

socket_bind :: (socket: Socket, address: *Address) -> int {
    sin: sockaddr_in6;
    sin.sin6_family = AF_INET6;

    if address {
        sin.sin6_port = host_to_net_endian_16(address.port);
        sin.sin6_addr = address.host;
        sin.sin6_scope_id = address.sin6_scope_id;
    } else {
        sin.sin6_port = 0;
        sin.sin6_addr = HOST_ANY;
        sin.sin6_scope_id = 0;
    }

    return bind(socket, cast(*sockaddr)*sin, size_of(sockaddr_in6));
}

get_socket_address :: (socket: Socket, address: *Address) -> bool {
    sin:     sockaddr_in6;
    sin_len :s32= xx size_of(sockaddr_in6);

    if getsockname(socket, cast(*sockaddr)*sin, *sin_len) == -1 return false;

    address.host = sin.sin6_addr;
    address.port = htons(sin.sin6_port);
    address.sin6_scope_id = xx sin.sin6_scope_id;

    return true;
}

socket_wait :: (socket: Socket, condition: *Socket_Wait, timeout: s64) -> Result_Status {
    #if OS == .WINDOWS {
        read_set:     fd_set;
        write_set:    fd_set;
        time:         timeval;
        select_count: int;

        time.tv_sec  = cast(s32)(timeout / 1000);
        time.tv_usec = cast(s32)(timeout % 1000) * 1000;

        if condition.* & .SEND then FD_SET(socket, *write_set);
        if condition.* & .RECEIVE then FD_SET(socket, *read_set);

        select_count = select(cast(s32)(socket + 1), *read_set, *write_set, null, *time);

        if select_count < 0 then return .ERROR;

        condition.* = .NONE;

        if select_count == 0 then return .NONE;
        if FD_ISSET(socket, *write_set) then condition.* |= .SEND;
        if FD_ISSET(socket, *read_set) then condition.* |= .RECEIVE;

    } else #if OS == .UNIX {
        poll_socket: pollfd;
        poll_count:  int;

        poll_socket.fd     = socket;
        poll_socket.events = 0;

        if condition.* & .WAIT_SEND then poll_socket.events |= POLLOUT;
        if condition.* & .WAIT_RECEIVE then poll_socket.events |= POLLIN;

        poll_count = poll(*poll_socket, 1, timeout);

        if poll_count < 0 {
            if errno() == EINTR && condition.* & .WAIT_INTERRUPT {
                condition.* = .WAIT_INTERRUPT;

                return .NONE;
            }

            return .ERROR;
        }

        condition.* = .WAIT_NONE;

        if poll_count == 0 then return .NONE;
        if poll_socket.revents & POLLOUT then condition.* |= .WAIT_SEND;
        if pollSocket.revents & POLLIN then condition.* |= .WAIT_RECEIVE;
    }

    return .NONE;
}

socket_send :: (socket: Socket, address: *Address, buffers: []Buffer, buffer_count: u32) -> (s32, socket_error: int = 0) {
    sin:         sockaddr_in6;
    sent_length: u32;

    #if OS == .WINDOWS {
        if address != null {
            sin.sin6_family = AF_INET6;
            sin.sin6_port = host_to_net_endian_16(address.port);
            sin.sin6_addr = address.host;
            sin.sin6_scope_id = address.sin6_scope_id;
        }

        buffer_size := 0;
        for 0..buffer_count-1 {
            buffer_size += buffers[it].length;
        }
        if WSASendTo(socket, cast(*WSABUF)buffers.data, xx buffer_count, *sent_length, 0, 
            ifx address then cast(*sockaddr)*sin else null,
            ifx address then cast(s32)size_of(sockaddr_in6) else cast(s32)0,
            null, null) == SOCKET_ERROR {

            error_no := WSAGetLastError();
            return ifx error_no == WSAEWOULDBLOCK then cast(s32)0 else cast(s32)-1, error_no;
        }
    } else #if OS == .UNIX {
        msg_header: msghdr;

        if address != null {
            sin.sin6_family = AF_INET6;
            sin.sin6_port = host_to_net_endian_16(address.port);
            sin.sin6_addr = address.host;
            sin.sin6_scope_id = address.sin6_scope_id;

            msg_header.msg_name = *sin;
            msg_header.msg_namelen = size_of(sockaddr_in6);
        }

        msg_header.msg_iov = cast(*iovec)buffers.data;
        msg_header.msg_iovlen = buffers.count - 1;

        sent_length = send(socket, *msg_header, MSG_NOSIGNAL);

        if sent_length == -1 {
            error_no := errno();
            if error_no == EWOULDBLOCK return cast(s32)0, error_no;

            return cast(s32)-1, error_no;
        }
    }

    return cast(s32)sent_length;
}

socket_receive :: (socket: Socket, address: *Address, buffers: []Buffer, buffer_count: u32) -> (s32, socket_error: int = 0) {
    sin:            sockaddr_in6;
    receive_length: s32;

    #if OS == .WINDOWS {
        flags:      u32;
        sin_length: s32 = size_of(sockaddr_in6);

        result := WSARecvFrom(socket, cast(*WSABUF)buffers.data, buffer_count, cast(*u32)*receive_length, *flags,
            ifx address then cast(*sockaddr)*sin else null,
            ifx address then *sin_length else null,
            null, null);

        if result == SOCKET_ERROR {
            error_no := WSAGetLastError();
            if error_no == {
                case WSAEWOULDBLOCK; 
                    return 0, error_no;
                case WSAECONNRESET; 
                    return 0, error_no;
                case WSAEMSGSIZE;
                    return -2;
            }

            log_error("Socket error from recvfrom %", error_no);
            return -1, error_no;
        }

        if flags & cast(u32)MSG.PARTIAL return -2;

        if address {
            address.host           = sin.sin6_addr;
            address.port           = net_to_host_endian_16(sin.sin6_port);
            address.sin6_scope_id  = xx sin.sin6_scope_id;
        }

    } else #if OS == .UNIX {
        msg_header: msghdr;
        msg_header.msg_name = *sin;
        msg_header.msg_namelen = size_of(sockaddr_in6);

        msg_header.msg_iov = buffers.data;
        msg_header.msg_iovlen = buffer_count;

        receive_length = recvmsg(socket, *msg_header, MSG_NOSIGNAL);

        if receive_length == -1 {
            error_no = errno();
            if err_no == EWOULDBLOCK return cast(u32)0, error_no;

            return -1, error_no;
        }

        if msg_header.msg_flags & MSG_TRUNC return -1;

        if address != null {
            address.host           = sin.sin6_addr;
            address.port           = net_to_host_endian_16(sin.sin6_port);
            address.sin6_scope_id  = xx sin.sin6_scope_id;
        }
    }

    return receive_length;
}

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

    data_total :u32= U32_MAX;
    bandwidth  :u32= U32_MAX;

    if host.outgoing_bandwidth != 0 {
        data_total = 0;
        bandwidth = (host.outgoing_bandwidth * cast(u32)elapsed_time) / 1000;

        for peer: host.peers {
            if peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER continue;
            data_total += peer.outgoing_data_total;
        }
    }

    needs_adjustment := host.bandwidth_limited_peers > 0;
    throttle :u32= 0;

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
        remaining_peers  = host.connected_peers;
        bandwidth        = host.incoming_bandwidth;
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

peer_receive :: (peer: *Peer, channel_id: *u8) -> *Packet {
    if list_empty(*peer.dispatched_commands) return null;

    incoming_cmd := cast(*Incoming_Command)list_remove(list_begin(*peer.dispatched_commands));

    if channel_id != null then channel_id.* = incoming_cmd.command.header.channel_id;

    packet := incoming_cmd.packet;
    packet.ref_count -= 1;

    if incoming_cmd.fragments {
        array_reset(*incoming_cmd.fragments);
    }

    free(incoming_cmd);
    peer.total_waiting_data -= packet.data_length;

    return packet;
}

peer_throttle :: (peer: *Peer, round_trip_time: s64) -> Result_Status {
    if peer.last_round_trip_time <= peer.last_round_trip_time_variance {
        peer.packet_throttle = peer.packet_throttle_limit;
    } else if round_trip_time < peer.last_round_trip_time {
        peer.packet_throttle += peer.packet_throttle_acceleration;
        
        if peer.packet_throttle > peer.packet_throttle_acceleration {
            peer.packet_throttle = peer.packet_throttle_limit;
        }

        return .SUCCESS;

    } else if round_trip_time > peer.last_round_trip_time + 2 * peer.last_round_trip_time_variance {
        if peer.packet_throttle > peer.packet_throttle_deceleration {
            peer.packet_throttle -= peer.packet_throttle_deceleration;
        } else {
            peer.packet_throttle = 0;
        }

        return .ERROR;
    }

    return .NONE;
}

peer_queue_outgoing_command :: (peer: *Peer, command: *Protocol, packet: *Packet, offset: u32, length: u16) -> *Outgoing_Command {
    outgoing_cmd := New(Outgoing_Command);

    outgoing_cmd.command = command.*;
    outgoing_cmd.fragment_offset = offset;
    outgoing_cmd.fragment_length = length;
    outgoing_cmd.packet = packet;

    if packet packet.ref_count += 1;

    peer_setup_outgoing_command(peer, outgoing_cmd);

    return outgoing_cmd;
}

peer_setup_outgoing_command :: (peer: *Peer, outgoing_cmd: *Outgoing_Command) {
    peer.outgoing_data_total += protocol_command_size(outgoing_cmd.command.header.command) + outgoing_cmd.fragment_length;

    if outgoing_cmd.command.header.channel_id == 0xFF {
        peer.outgoing_reliable_seq_number += 1;
        outgoing_cmd.reliable_seq_number = peer.outgoing_reliable_seq_number;
        outgoing_cmd.unreliable_seq_number = 0;
    } else if outgoing_cmd.command.header.command & Protocol_Command.FLAG_ACKNOWLEDGE {
        channel := *peer.channels[outgoing_cmd.command.header.channel_id];
        channel.outgoing_reliable_seq_number += 1;
        outgoing_cmd.reliable_seq_number = channel.outgoing_reliable_seq_number;
        outgoing_cmd.unreliable_seq_number = 0;
    } else if outgoing_cmd.command.header.command & Protocol_Command.FLAG_UNSEQUENCED {
        peer.outgoing_unsequenced_group += 1;
        outgoing_cmd.reliable_seq_number = 0;
        outgoing_cmd.unreliable_seq_number = 0;
    } else {
        channel := *peer.channels[outgoing_cmd.command.header.channel_id];

        if outgoing_cmd.fragment_offset == 0 channel.outgoing_unreliable_seq_number += 1;

        outgoing_cmd.reliable_seq_number = channel.outgoing_reliable_seq_number;
        outgoing_cmd.unreliable_seq_number = channel.outgoing_unreliable_seq_number;
    }

    outgoing_cmd.send_attempts = 0;
    outgoing_cmd.sent_time = 0;
    outgoing_cmd.round_trip_timeout = 0;
    outgoing_cmd.round_trip_timeout_limit = 0;
    outgoing_cmd.command.header.reliable_seq_number = host_to_net_endian_16(outgoing_cmd.reliable_seq_number);

    if outgoing_cmd.command.header.command & .MASK == {
        case .SEND_UNRELIABLE;
            outgoing_cmd.command.send_unreliable.unreliable_seq_number = host_to_net_endian_16(outgoing_cmd.unreliable_seq_number);
        case .SEND_UNSEQUENCED;
            outgoing_cmd.command.send_unsequenced.unsequenced_group = host_to_net_endian_16(peer.outgoing_unsequenced_group);
    }    

    if outgoing_cmd.command.header.command & .FLAG_ACKNOWLEDGE {
        list_insert(list_end(*peer.outgoing_reliable_commands), outgoing_cmd);
    } else {
        list_insert(list_end(*peer.outgoing_unreliable_commands), outgoing_cmd);
    }
}

peer_queue_acknowledgement :: (peer: *Peer, command: *Protocol, sent_time: u16) -> *Acknowledgement {
    if command.header.channel_id < peer.channels.count {
        channel := *peer.channels[command.header.channel_id];
        reliable_window := command.header.reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;
        current_window := channel.incoming_reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;

        if command.header.reliable_seq_number < channel.incoming_reliable_seq_number then reliable_window += PEER_RELIABLE_WINDOWS;

        if reliable_window >= current_window + PEER_FREE_RELIABLE_WINDOWS - 1 && reliable_window <= current_window + PEER_FREE_RELIABLE_WINDOWS {
            return null;
        }
    }

    acknowledgement := New(Acknowledgement);
    
    peer.outgoing_data_total += size_of(Acknowledgement);
    acknowledgement.sent_time = sent_time;
    acknowledgement.command = command.*;

    list_insert(list_end(*peer.acknowledgements), acknowledgement);
    return acknowledgement;
}

peer_queue_incoming_command :: (peer: *Peer, command: *Protocol, data: *void, data_length: u32, flags: Packet_Flags, fragment_count: u32) -> *Incoming_Command {
    packet: *Packet;
    channel := *peer.channels[command.header.channel_id];

    // The original c version uses goto
    // so this is a way to get around not having gotos in this language
    do_error :: (discard: bool) #expand {
        if discard {
            if `fragment_count <= 0 {
                if `packet != null && `packet.ref_count == 0 {
                    packet_destroy(`packet);
                }

                `return *DUMMY_COMMAND;
            }
        } else {
           if `packet != null && `packet.ref_count == 0 {
                packet_destroy(`packet);
            }

            `return null;
        }
    }

    if peer.state == .DISCONNECT_LATER do_error(true);

    unreliable_seq_number: u32;
    reliable_seq_number:   u32;
    reliable_window:       u16;
    current_window:        u16;
    current_cmd:          *List_Node;

    if command.header.command  & .MASK != .SEND_UNSEQUENCED {
        reliable_seq_number = command.header.reliable_seq_number;
        reliable_window = cast(u16)(reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE);
        current_window = channel.incoming_reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;

        if reliable_seq_number < channel.incoming_reliable_seq_number {
            reliable_window += PEER_RELIABLE_WINDOWS;
        }

        if reliable_window < current_window || reliable_window >= current_window + PEER_FREE_RELIABLE_WINDOWS - 1 {
            do_error(true);
        }
    }

    if command.header.command & .MASK == {
        case .SEND_FRAGMENT; #through;
        case .SEND_RELIABLE;
            if reliable_seq_number == channel.incoming_reliable_seq_number do_error(true);

            current_cmd = list_previous(list_end(*channel.incoming_reliable_commands));
            for :reverse channel.incoming_reliable_commands {
                incoming_cmd := cast(*Incoming_Command)it;
                current_cmd = it;

                if reliable_seq_number >= channel.incoming_reliable_seq_number {
                    if incoming_cmd.reliable_seq_number < channel.incoming_reliable_seq_number {
                        continue;
                    }
                } else if incoming_cmd.reliable_seq_number >= channel.incoming_reliable_seq_number {
                    break;
                }

                if incoming_cmd.reliable_seq_number <= reliable_seq_number {
                    if incoming_cmd.reliable_seq_number < reliable_seq_number {
                        break;
                    }
                    do_error(true);
                }
            }
        case .SEND_UNRELIABLE; #through;
        case .SEND_UNRELIABLE_FRAGMENT;
            unreliable_seq_number = net_to_host_endian_16(command.send_unreliable.unreliable_seq_number);

            if reliable_seq_number == channel.incoming_reliable_seq_number && unreliable_seq_number <= channel.incoming_unreliable_seq_number do_error(true);

            current_cmd = list_previous(list_end(*channel.incoming_unreliable_commands));
            for :reverse channel.incoming_unreliable_commands {
                incoming_cmd := cast(*Incoming_Command)it;
                current_cmd = it;

                if command.header.command == .SEND_UNSEQUENCED continue;

                if reliable_seq_number >= channel.incoming_reliable_seq_number {
                    if incoming_cmd.reliable_seq_number < channel.incoming_reliable_seq_number {
                        continue;
                    }
                } else if incoming_cmd.reliable_seq_number >= channel.incoming_reliable_seq_number {
                    break;
                }

                if incoming_cmd.reliable_seq_number < reliable_seq_number break;
                if incoming_cmd.reliable_seq_number > reliable_seq_number continue;

                if incoming_cmd.unreliable_seq_number <= unreliable_seq_number {
                    if incoming_cmd.unreliable_seq_number < unreliable_seq_number break;

                    do_error(true);
                }
            }
        case .SEND_UNSEQUENCED;
            current_cmd = list_end(*channel.incoming_unreliable_commands);
        case;
            do_error(true);
    }

    if peer.total_waiting_data >= peer.host.maximum_waiting_data do_error(false);

    packet = packet_create(data, data_length, flags);
    
    incoming_cmd := New(Incoming_Command);

    incoming_cmd.reliable_seq_number = command.header.reliable_seq_number;
    incoming_cmd.unreliable_seq_number = cast(u16)(unreliable_seq_number & 0xFFFF);
    incoming_cmd.command = command.*;
    incoming_cmd.fragment_count = fragment_count;
    incoming_cmd.fragments_remaining = fragment_count;
    incoming_cmd.packet = packet;

    if fragment_count > 0 {
        if fragment_count <= PROTOCOL_MAX_FRAGMENT_COUNT {
            incoming_cmd.fragments = NewArray((fragment_count + 31) / 32, u32);
        }

        memset(incoming_cmd.fragments.data, 0, (fragment_count + 31) / 32 * size_of(u32));
    }

    assert(packet != null);
    packet.ref_count += 1;
    peer.total_waiting_data += packet.data_length;

    list_insert(list_next(current_cmd), incoming_cmd);

    if command.header.command & .MASK == {
        case .SEND_FRAGMENT; #through;
        case .SEND_RELIABLE; 
            peer_dispatch_incoming_reliable_commands(peer, channel);
        case;
            peer_dispatch_incoming_unreliable_commands(peer, channel);
    }

    return incoming_cmd;
}

peer_dispatch_incoming_reliable_commands :: (peer: *Peer, channel: *Channel) {
    current_cmd := list_begin(*channel.incoming_reliable_commands);

    for channel.incoming_reliable_commands {
        incoming_cmd := cast(*Incoming_Command)it;
        current_cmd = it;

        if incoming_cmd.fragments_remaining > 0 || incoming_cmd.reliable_seq_number != cast(u16)(channel.incoming_reliable_seq_number + 1) break;

        channel.incoming_reliable_seq_number = incoming_cmd.reliable_seq_number;

        if incoming_cmd.fragment_count > 0 then channel.incoming_reliable_seq_number += cast(u16)(incoming_cmd.fragment_count - 1);

        current_cmd = list_next(current_cmd);
    }

    if current_cmd == list_begin(*channel.incoming_reliable_commands) return;

    channel.incoming_unreliable_seq_number = 0;

    list_move(list_end(*peer.dispatched_commands), list_begin(*channel.incoming_reliable_commands), list_previous(current_cmd));

    if !peer.needs_dispatch {
        list_insert(list_end(*peer.host.dispatch_queue), peer);
        peer.needs_dispatch = true;
    }

    if !list_empty(*channel.incoming_unreliable_commands) {
        peer_dispatch_incoming_unreliable_commands(peer, channel);
    }
}

peer_dispatch_incoming_unreliable_commands :: (peer: *Peer, channel: *Channel) {
    dropped_cmd := list_begin(*channel.incoming_unreliable_commands);
    start_cmd   := dropped_cmd;
    current_cmd := dropped_cmd;

    while current_cmd != list_end(*channel.incoming_unreliable_commands) {
        incoming_cmd := cast(*Incoming_Command)current_cmd;

        if incoming_cmd.command.header.command & .MASK == .SEND_UNSEQUENCED then {
            current_cmd = list_next(current_cmd);
            continue;
        }

        if incoming_cmd.reliable_seq_number == channel.incoming_reliable_seq_number {
            if incoming_cmd.fragments_remaining <= 0 {
                channel.incoming_unreliable_seq_number = incoming_cmd.unreliable_seq_number;
                current_cmd = list_next(current_cmd);
                continue;
            }

            if start_cmd != current_cmd {
                list_move(list_end(*peer.dispatched_commands), start_cmd, list_previous(current_cmd));

                if !peer.needs_dispatch {
                    list_insert(list_end(*peer.dispatched_commands), peer);
                    peer.needs_dispatch = true;
                }


                dropped_cmd = current_cmd;
            } else if dropped_cmd != current_cmd {
                dropped_cmd = list_previous(current_cmd);
            }
        } else {

            reliable_window := incoming_cmd.reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;
            current_window := channel.incoming_reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;

            if incoming_cmd.reliable_seq_number < channel.incoming_reliable_seq_number {
                reliable_window += PEER_RELIABLE_WINDOWS;
            }

            if reliable_window >= current_window && reliable_window < current_window + PEER_FREE_RELIABLE_WINDOWS -1 then break;

            dropped_cmd = list_next(current_cmd);

            if start_cmd != current_cmd {
                list_move(list_next(*peer.dispatched_commands), start_cmd, list_previous(current_cmd));

                if !peer.needs_dispatch {
                    list_insert(list_end(*peer.host.dispatch_queue), peer);
                    peer.needs_dispatch = true;
                }
            }
        }

        start_cmd = list_next(current_cmd);
        current_cmd = list_next(current_cmd);
    }

    if start_cmd != current_cmd {
        list_move(list_end(*peer.dispatched_commands), start_cmd, list_previous(current_cmd));

        if !peer.needs_dispatch {
            list_insert(list_end(*peer.host.dispatch_queue), peer);
            peer.needs_dispatch = true;
        }

        dropped_cmd = current_cmd;
    }

    peer_remove_incoming_commands(*channel.incoming_unreliable_commands, list_begin(*channel.incoming_unreliable_commands), dropped_cmd);
}

peer_remove_incoming_commands :: (list: *List, start_cmd: *List_Node, end_cmd: *List_Node) {
    current_cmd := start_cmd;
    while current_cmd != end_cmd {
        incoming_cmd := cast(*Incoming_Command)current_cmd;

        current_cmd = list_next(current_cmd);
        list_remove(incoming_cmd);

        if incoming_cmd.packet != null {
            incoming_cmd.packet.ref_count -= 1;

            if incoming_cmd.packet.ref_count == 0 then packet_destroy(incoming_cmd.packet);
        }

        if incoming_cmd.fragments.count > 0 then array_reset(*incoming_cmd.fragments);

        free(incoming_cmd);
    }
}

protocol_command_size :: inline (command: Protocol_Command) -> u32 {
    return PROTOCOL_COMMAND_SIZES[cast(u32)(command & .MASK)];
}

protocol_send_outgoing_commands :: (host: *Host, event: *Event, check_for_timeouts: bool) -> Result_Status {
    header_data: [size_of(Protocol_Header) + size_of(u32)]u8;
    header: *Protocol_Header = cast(*Protocol_Header)header_data.data;
    host.continue_sending = true;

    while host.continue_sending {
        host.continue_sending = false;
        for * peer: host.peers {
            if peer.state == .DISCONNECTED || peer.state == .ZOMBIE then continue;

            host.header_flags = 0;
            host.command_count = 0;
            host.buffer_count = 1;
            host.packet_size = size_of(Protocol_Header);

            if !list_empty(*peer.acknowledgements) {
                protocol_send_acknowledgements(host, peer);
            }

            if check_for_timeouts && !list_empty(*peer.sent_reliable_commands) && 
                host.service_time >= peer.next_timeout &&
                protocol_check_timeouts(host, peer, event) == true {

                if event && event.type != .NONE { 
                    return .SUCCESS;
                } else {
                    continue;
                }
            }

            should_ping := protocol_send_reliable_outgoing_commands(host, peer);

            if (list_empty(*peer.outgoing_reliable_commands) || should_ping) &&
                list_empty(*peer.sent_reliable_commands) && 
                time_difference(host.service_time, peer.last_received_time) >= peer.ping_interval &&
                peer.mtu - host.packet_size >= size_of(Protocol_Ping) 
             {
                peer_ping(peer);
                protocol_send_reliable_outgoing_commands(host, peer);
            }

            if !list_empty(*peer.outgoing_unreliable_commands) {
                protocol_send_unreliable_outgoing_commands(host, peer);
            }

            if host.command_count == 0 {
                continue;
            }

            if peer.packet_loss_epoch == 0 { // :Time
                peer.packet_loss_epoch = host.service_time;
            } else if time_difference(host.service_time, peer.packet_loss_epoch) >= PEER_PACKET_LOSS_INTERVAL && peer.packets_sent > 0 {
                packet_loss := peer.packets_lost * PEER_PACKET_LOSS_SCALE / peer.packets_sent; 
                peer.packet_loss_variance -= peer.packet_loss_variance / 4;

                // if context.log_level >= .VERBOSE {
                    log("Peer % packets lost: % packet loss: % packet loss adjusted: % variance: %\n",
                        peer.incoming_peer_id,
                        peer.packets_lost,
                        packet_loss,
                        peer.packet_loss,
                        peer.packet_loss_variance,
                        flags=.VERBOSE_ONLY);
                // }

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

            host.buffers[0].data = cast(*u8)*header_data;
            if host.header_flags & PROTOCOL_FLAG_SENT_TIME {
                // :Time
                header.sent_time = host_to_net_endian_16(cast(u16)(host.service_time & 0xFFFF));
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

            header.peer_id = host_to_net_endian_16(cast(u16)(peer.outgoing_peer_id | host.header_flags));

            // @TODO :checksum
            // if host.checksum != null { }

            // @TODO :compression
            // if should_compress { }

            peer.last_sent_time = host.service_time;

            sent_length, socket_error := socket_send(host.socket, *peer.address, host.buffers, host.buffer_count);
            protocol_remove_sent_unreliable_commands(peer);

            if sent_length < 0 {
                host.buffers[0].data = null;
                return .ERROR;
            }

            host.total_sent_data += xx sent_length;
            peer.total_data_sent += xx sent_length;
            host.total_sent_packets += 1;
        }
    }

    host.buffers[0].data = null;
    return .NONE;
}

protocol_receive_incoming_commands :: (host: *Host, event: *Event) -> Result_Status {
    for 0..255 {
        buffer: [1]Buffer;
        buffer[0].data = host.packet_data.data;
        buffer[0].length = xx host.mtu;

        received_length, socket_error := socket_receive(host.socket, *host.received_address, buffer, 1);

        if received_length == -2 {
            continue;
        }
        if received_length < 0 {
            log_error("Socket error trying to receive packets: %", socket_error);
            return .ERROR;
        }
        if received_length == 0 {
            return .NONE;
        }

        host.received_data = host.packet_data.data;
        host.received_data_length = xx received_length;
        host.total_received_data_length += xx received_length;
        host.total_received_packets += 1;

        // @TODO
        // if host.intercept !== null { }

        if protocol_handle_incoming_commands(host, event) == {
            case .SUCCESS; return .SUCCESS;
            case .ERROR; {
                log("Error handling incoming commands");
                return .ERROR;
            }
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
                    list_insert(list_end(*host.dispatch_queue), peer);
                }

                return .SUCCESS;
        }
    }

    return .NONE;
}

protocol_send_acknowledgements :: (host: *Host, peer: *Peer) {
    command := *host.commands[host.command_count];
    buffer := host.buffers.data + host.buffer_count;

    current_ack := list_begin(*peer.acknowledgements); 

    while current_ack != list_end(*peer.acknowledgements) {
        // @TODO :fix_loop_check
        if (command - host.commands.data) >= PROTOCOL_MAX_PACKET_COMMANDS ||
            (buffer - host.buffers.data) >= MAX_BUFFER_COUNT ||
            peer.mtu - host.packet_size < size_of(Protocol_Acknowledge) {

            host.continue_sending = true;
            break;
        }

        ack := cast(*Acknowledgement)current_ack;
        current_ack = list_next(current_ack);

        buffer.data = cast(*u8)command;
        buffer.length = size_of(Protocol_Acknowledge);
        host.packet_size += xx buffer.length;

        reliable_seq_number := host_to_net_endian_16(ack.command.header.reliable_seq_number);

        command.header.command = Protocol_Command.ACKNOWLEDGE;
        command.header.channel_id = ack.command.header.channel_id;
        command.header.reliable_seq_number = reliable_seq_number;
        command.acknowledge.received_reliable_seq_number = reliable_seq_number;
        command.acknowledge.received_sent_time = host_to_net_endian_16(ack.sent_time);

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

        if time_difference(host.service_time, outgoing_cmd.sent_time) < outgoing_cmd.round_trip_timeout {
            continue;
        }

        if peer.earliest_timeout == 0 || outgoing_cmd.sent_time < peer.earliest_timeout {
            peer.earliest_timeout = outgoing_cmd.sent_time;
        }

        peer_timeout_time := time_difference(host.service_time, peer.earliest_timeout);
        
        if peer.earliest_timeout != 0 && (peer_timeout_time >= peer.timeout_maximum ||
            (outgoing_cmd.round_trip_timeout >= outgoing_cmd.round_trip_timeout_limit &&
            peer_timeout_time >= peer.timeout_minimum)) {

            if context.log_level >= .VERBOSE {
                log("Peer %: service_time: % peer timeout time: % (min: % max: %) round trip timeout: % / %\n", 
                    peer.incoming_peer_id,
                    host.service_time,
                    peer_timeout_time,
                    peer.timeout_minimum,
                    peer.timeout_maximum,
                    outgoing_cmd.round_trip_timeout,
                    outgoing_cmd.round_trip_timeout_limit,
                    flags=.VERBOSE_ONLY);
            }

            protocol_notify_disconnect_timeout(host, peer, event);
            return true;
        }

        if outgoing_cmd.packet {
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
    buffer := host.buffers.data + host.buffer_count;

    window_wrap := false;
    window_exceeded := false;
    can_ping := true;

    current_cmd := list_begin(*peer.outgoing_reliable_commands);

    while current_cmd != list_end(*peer.outgoing_reliable_commands) {
        outgoing_cmd := cast(*Outgoing_Command)current_cmd;

        channel := ifx outgoing_cmd.command.header.channel_id < peer.channels.count then *peer.channels[outgoing_cmd.command.header.channel_id] else cast(*Channel)null;
        reliable_window := outgoing_cmd.reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;

        if channel {
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
            window_size := 0;
            if !window_exceeded {
                window_size = (peer.packet_throttle * peer.window_size) / PEER_PACKET_THROTTLE_SCALE;

                if peer.reliable_data_in_transit + outgoing_cmd.fragment_length > max(window_size, peer.mtu) {
                    window_exceeded = true;
                }
            }

            if window_exceeded {
                current_cmd = list_next(current_cmd);
                continue;
            }
        }

        can_ping = false;
        cmd_size := protocol_command_size(outgoing_cmd.command.header.command);

        if cmd - host.commands.data >= PROTOCOL_MAX_PACKET_COMMANDS ||
            (buffer+1) - host.buffers.data >= cast(u32)(MAX_BUFFER_COUNT) ||
            peer.mtu - host.packet_size < cmd_size ||
            (outgoing_cmd.packet != null &&
            cast(u16)(peer.mtu - host.packet_size) < cast(u16)(cmd_size + outgoing_cmd.fragment_length)) {
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

        outgoing_cmd.sent_time = host.service_time;

        buffer.data = cast(*u8)cmd;
        buffer.length = cmd_size;

        host.packet_size += cast(u32)buffer.length;
        host.header_flags |= PROTOCOL_FLAG_SENT_TIME;

        cmd.* = outgoing_cmd.command;

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

protocol_send_unreliable_outgoing_commands :: (host: *Host, peer: *Peer) {
    command := *host.commands[host.command_count];
    buffer := host.buffers.data + host.buffer_count;

    current_cmd := list_begin(*peer.outgoing_unreliable_commands);
    while current_cmd != list_end(*peer.outgoing_unreliable_commands) {
        outgoing_cmd := cast(*Outgoing_Command)current_cmd;
        cmd_size := protocol_command_size(outgoing_cmd.command.header.command);

        if command - host.commands.data >= PROTOCOL_MAX_PACKET_COMMANDS ||
            (buffer + 1) - host.buffers.data >= MAX_BUFFER_COUNT ||
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

        buffer.data = cast(*u8)command;
        buffer.length = cmd_size;
        host.packet_size += buffer.length;
        command.* = outgoing_cmd.command;
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

            if outgoing_cmd.packet.ref_count <= 0 {
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
        list_insert(list_end(*host.dispatch_queue), peer);
        peer.needs_dispatch = true;
    }
}

protocol_handle_verify_connect :: (host: *Host, event: *Event, peer: *Peer, command: Protocol) -> Result_Status {
    if peer.state != .CONNECTING then return .NONE;

    channel_count := net_to_host_endian_32(command.verify_connect.channel_count);

    // @TODO :giant_if
    if channel_count < PROTOCOL_MIN_CHANNEL_COUNT || channel_count > PROTOCOL_MAX_CHANNEL_COUNT ||
        net_to_host_endian_32(command.verify_connect.packet_throttle_interval) != peer.packet_throttle_interval ||
        net_to_host_endian_32(command.verify_connect.packet_throttle_acceleration) != peer.packet_throttle_acceleration ||
        net_to_host_endian_32(command.verify_connect.packet_throttle_deceleration) != peer.packet_throttle_deceleration ||
        command.verify_connect.connect_id != peer.connect_id {
        
        peer.event_data = 0;
        protocol_dispatch_state(host, peer, .ZOMBIE);
        return .ERROR;
    }

    protocol_remove_sent_reliable_command(peer, 1, 0xFF);

    if channel_count < peer.channels.count {
        array_reset(*peer.channels);
        peer.channels = NewArray(channel_count, Channel);

        for * channel: peer.channels channel_reset(channel);
    }

    peer.outgoing_peer_id = net_to_host_endian_16(command.verify_connect.outgoing_peer_id);
    peer.incoming_session_id = command.verify_connect.incoming_session_id;
    peer.outgoing_session_id = command.verify_connect.outgoing_session_id;

    mtu := net_to_host_endian_32(command.verify_connect.mtu);

    if mtu < PROTOCOL_MIN_MTU then mtu = PROTOCOL_MIN_MTU;
    else if mtu > PROTOCOL_MAX_MTU then mtu = PROTOCOL_MAX_MTU;

    if mtu < peer.mtu then peer.mtu = mtu;
    
    window_size := net_to_host_endian_32(command.verify_connect.window_size);
    if window_size < PROTOCOL_MIN_WINDOW_SIZE then window_size = PROTOCOL_MIN_WINDOW_SIZE;
    else if window_size > PROTOCOL_MAX_WINDOW_SIZE then window_size = PROTOCOL_MAX_WINDOW_SIZE;

    if window_size < peer.window_size then peer.window_size = window_size;

    peer.incoming_bandwidth = net_to_host_endian_32(command.verify_connect.incoming_bandwidth);
    peer.outgoing_bandwidth = net_to_host_endian_32(command.verify_connect.outgoing_bandwidth);

    protocol_notify_connect(host, peer, event);
    return .NONE;
}

protocol_remove_sent_reliable_command :: (peer: *Peer, reliable_seq_number: u16, channel_id: u8) -> Protocol_Command {
    outgoing_cmd: *Outgoing_Command = null;
    was_sent := true;

    for peer.sent_reliable_commands {
        outgoing_cmd = cast(*Outgoing_Command)it;
        if outgoing_cmd.reliable_seq_number == reliable_seq_number && outgoing_cmd.command.header.channel_id == channel_id {
            break;
        }
    }

    if outgoing_cmd == cast(*Outgoing_Command)list_end(*peer.sent_reliable_commands) {
        for * peer.outgoing_reliable_commands {
            outgoing_cmd = cast(*Outgoing_Command)it;

            if outgoing_cmd.send_attempts < 1 {
                return .NONE;
            }
            if outgoing_cmd.reliable_seq_number == reliable_seq_number && outgoing_cmd.command.header.channel_id == channel_id then break;
        }

        if outgoing_cmd == cast(*Outgoing_Command)list_end(*peer.outgoing_reliable_commands) {
            return .NONE;
        }
        was_sent = false;
    }

    if outgoing_cmd == null { 
        return .NONE;
    }

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

    if outgoing_cmd.packet {
        if was_sent {
            peer.reliable_data_in_transit -= outgoing_cmd.fragment_length;
        } 

        outgoing_cmd.packet.ref_count -= 1;

        if outgoing_cmd.packet.ref_count <= 0 {
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
    if host.received_data_length < size_of(u16) {
        return .NONE;
    }

    header := cast(*Protocol_Header)host.received_data;

    peer_id_endianed :u16= net_to_host_endian_16(header.peer_id);
    session_id := (peer_id_endianed & PROTOCOL_SESSION_MASK) >> PROTOCOL_SESSION_SHIFT;
    flags := peer_id_endianed & PROTOCOL_FLAG_MASK;
    peer_id := peer_id_endianed & ~(cast(u16)PROTOCOL_FLAG_MASK | cast(u16)PROTOCOL_SESSION_MASK);

    // size_of(u16) = offset_of sent_time from Protocol_Header
    header_size := ifx flags & PROTOCOL_FLAG_SENT_TIME then size_of(Protocol_Header) else size_of(u16);

    // @TODO :checksum support
    // if host.checksum != null header_size += size_of(u32);

    peer: *Peer;
    if peer_id == PROTOCOL_MAX_PEER_ID {
        peer = null;
    } else if peer_id >= host.peers.count {
        return .NONE;
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
    //     log_error("enet: compression is not yet supported");
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
    command: *Protocol;

    exit_proc :: () #expand {
        if `event != null && `event.type != .NONE `return .SUCCESS;
        `return .NONE;
    }

    while current_data < host.received_data + host.received_data_length {
        command = cast(*Protocol)current_data;

        if current_data + size_of(Protocol_Command_Header) > host.received_data + host.received_data_length {
            break;
        }

        command_number := command.header.command & .MASK;
        if command_number > PROTOCOL_COMMAND_COUNT break;

        command_size := protocol_command_size(command_number);

        if command_size == 0 || current_data + command_size > host.received_data + host.received_data_length {
            break;
        }

        current_data += command_size;

        if peer == null && (command_number != .CONNECT || current_data < host.received_data + host.received_data_length) {
            break;
        }

        command.header.reliable_seq_number = net_to_host_endian_16(command.header.reliable_seq_number);

        if command_number == {
            case .ACKNOWLEDGE; if protocol_handle_acknowledge(host, event, peer, command) != .NONE then exit_proc();
            case .CONNECT; 
                if peer != null exit_proc();
                peer = protocol_handle_connect(host, header, command);
                if peer == null exit_proc();
            case .VERIFY_CONNECT;   if protocol_handle_verify_connect(host, event, peer, command) != .NONE then exit_proc();
            case .DISCONNECT;       if protocol_handle_disconnect(host, peer, command) != .NONE then exit_proc();
            case .PING;             if protocol_handle_ping(host, peer, command) != .NONE then exit_proc();
            case .SEND_RELIABLE;    if protocol_handle_send_reliable(host, peer, command, *current_data) != .NONE then exit_proc();
            case .SEND_UNRELIABLE;  if protocol_handle_send_unreliable(host, peer, command, *current_data) != .NONE then exit_proc();
            case .SEND_UNSEQUENCED; if protocol_handle_send_unsequenced(host, peer, command, *current_data) != .NONE then exit_proc();
            case .SEND_FRAGMENT;    if protocol_handle_send_fragment(host, peer, command, *current_data) != .NONE then exit_proc();
            case .BANDWIDTH_LIMIT;  if protocol_handle_bandwidth_limit(host, peer, command) != .NONE then exit_proc();
            case .THROTTLE_CONFIGURE; if protocol_handle_throttle_configure(host, peer, command) != .NONE then exit_proc();
            case .SEND_UNRELIABLE_FRAGMENT; if protocol_handle_send_unreliable_fragment(host, peer, command, *current_data) != .NONE then exit_proc();
            case; exit_proc();
        }

        assert(peer != null);
        if command.header.command & .FLAG_ACKNOWLEDGE {
            if !(flags & PROTOCOL_FLAG_SENT_TIME) break;

            sent_time := net_to_host_endian_16(header.sent_time);

            if peer.state == {
                case .DISCONNECTING; #through;
                case .ACKNOWLEDGING_CONNECT; #through;
                case .DISCONNECTED; #through;
                case .ZOMBIE; // do nothing 
                case .ACKNOWLEDGING_DISCONNECT;
                    if command.header.command & .MASK == .DISCONNECT {
                        peer_queue_acknowledgement(peer, command, sent_time);
                    }
                case;
                    peer_queue_acknowledgement(peer, command, sent_time);
            }
        }
    }

    exit_proc();
}


protocol_handle_acknowledge :: (host: *Host, event: *Event, peer: *Peer, command: Protocol) -> Result_Status {
    if peer.state == .DISCONNECTED || peer.state == .ZOMBIE return .NONE;

    // :Time
    received_sent_time := cast(s64)net_to_host_endian_16(command.acknowledge.received_sent_time);
    received_sent_time |= host.service_time & 0xFFFF0000;
    if received_sent_time & 0x8000 > host.service_time & 0x8000 then received_sent_time -= 0x10000;

    if host.service_time < received_sent_time {
        return .NONE;
    }

    peer.last_received_time = host.service_time;
    peer.earliest_timeout = 0;
    round_trip_time := time_difference(host.service_time, received_sent_time);

    peer_throttle(peer, round_trip_time);
    peer.round_trip_time_variance -= peer.round_trip_time_variance / 4;

    if round_trip_time >= peer.round_trip_time {
        peer.round_trip_time          += (round_trip_time - peer.round_trip_time) / 8;
        peer.round_trip_time_variance += (round_trip_time - peer.round_trip_time) / 4;
    } else {
        peer.round_trip_time          -= (peer.round_trip_time - round_trip_time) / 8;
        peer.round_trip_time_variance += (peer.round_trip_time - round_trip_time) / 4;
    }

    if peer.round_trip_time < peer.lowest_round_trip_time then peer.lowest_round_trip_time = peer.round_trip_time;

    if peer.round_trip_time_variance > peer.highest_round_trip_time_variance {
        peer.highest_round_trip_time_variance = peer.round_trip_time_variance;
    }

    if peer.packet_throttle_epoch == 0 || time_difference(host.service_time, peer.packet_throttle_epoch) >= peer.packet_throttle_interval {
        peer.last_round_trip_time             = peer.lowest_round_trip_time;
        peer.last_round_trip_time_variance    = peer.highest_round_trip_time_variance;
        peer.lowest_round_trip_time           = peer.round_trip_time;
        peer.highest_round_trip_time_variance = peer.round_trip_time_variance;
        peer.packet_throttle_epoch            = host.service_time;
    }

    received_reliable_seq_number := net_to_host_endian_16(command.acknowledge.received_reliable_seq_number);
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
    }

    return .NONE;
}

protocol_handle_connect :: (host: *Host, header: *Protocol_Header, command: Protocol) -> *Peer {
    channel_count := net_to_host_endian_32(command.connect.channel_count);

    if channel_count < PROTOCOL_MIN_CHANNEL_COUNT || channel_count > PROTOCOL_MAX_CHANNEL_COUNT return null;

    duplicate_peers: u32;
    peer: *Peer;

    for * current_peer: host.peers {
        if current_peer.state == .DISCONNECTED && !peer {
            peer = current_peer;
        } else if current_peer.state != .CONNECTING && in6_equal(current_peer.address.host, host.received_address.host) {
            if current_peer.address.port == host.received_address.port && current_peer.connect_id == command.connect.connect_id return null;

            duplicate_peers += 1;
        }
    }

    if !peer || duplicate_peers >= host.duplicate_peers return null;

    if channel_count > host.channel_limit channel_count = host.channel_limit;

    peer.channels   = NewArray(channel_count, Channel);
    peer.state      = .ACKNOWLEDGING_CONNECT;
    peer.connect_id = command.connect.connect_id;
    peer.address    = host.received_address;
    peer.event_data = net_to_host_endian_32(command.connect.data);

    peer.outgoing_peer_id   = net_to_host_endian_16(command.connect.outgoing_peer_id);
    peer.incoming_bandwidth = net_to_host_endian_32(command.connect.incoming_bandwidth);
    peer.outgoing_bandwidth = net_to_host_endian_32(command.connect.outgoing_bandwidth);

    peer.packet_throttle_interval     = net_to_host_endian_32(command.connect.packet_throttle_interval);
    peer.packet_throttle_acceleration = net_to_host_endian_32(command.connect.packet_throttle_acceleration);
    peer.packet_throttle_deceleration = net_to_host_endian_32(command.connect.packet_throttle_deceleration);

    shift_session_id :: inline (session_id: u8) -> u8 {
        return (session_id + 1) & (PROTOCOL_SESSION_MASK >> PROTOCOL_SESSION_SHIFT);
    }

    incoming_session_id := ifx command.connect.incoming_session_id == 0xFF then peer.outgoing_session_id else command.connect.incoming_session_id;
    incoming_session_id = shift_session_id(incoming_session_id);
    if incoming_session_id == peer.outgoing_session_id then incoming_session_id = shift_session_id(incoming_session_id);
    peer.outgoing_session_id = incoming_session_id;

    outgoing_session_id := ifx command.connect.outgoing_session_id == 0xFF then peer.incoming_session_id else command.connect.outgoing_session_id;
    outgoing_session_id = shift_session_id(outgoing_session_id);
    if outgoing_session_id == peer.incoming_session_id then outgoing_session_id = shift_session_id(outgoing_session_id);
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

    peer.mtu = min(max(net_to_host_endian_32(command.connect.mtu), PROTOCOL_MIN_MTU), PROTOCOL_MAX_MTU);

    if host.outgoing_bandwidth == 0 && peer.incoming_bandwidth == 0 {
        peer.window_size = PROTOCOL_MAX_WINDOW_SIZE;
    } else if host.outgoing_bandwidth == 0 || peer.incoming_bandwidth == 0 {
        peer.window_size = (max(host.outgoing_bandwidth, peer.incoming_bandwidth) / PEER_WINDOW_SIZE_SCALE) * PROTOCOL_MIN_WINDOW_SIZE;
    } else {
        peer.window_size = (min(host.outgoing_bandwidth, peer.incoming_bandwidth) / PEER_WINDOW_SIZE_SCALE) * PROTOCOL_MIN_WINDOW_SIZE;
    }

    if peer.window_size < PROTOCOL_MIN_WINDOW_SIZE {
        peer.window_size = PROTOCOL_MIN_WINDOW_SIZE;
    } else if peer.window_size > PROTOCOL_MAX_WINDOW_SIZE {
        peer.window_size = PROTOCOL_MAX_WINDOW_SIZE;
    }

    window_size: u32;
    if host.incoming_bandwidth == 0 {
        window_size = PROTOCOL_MAX_WINDOW_SIZE;
    } else {
        window_size = (host.incoming_bandwidth / PEER_WINDOW_SIZE_SCALE) * PROTOCOL_MIN_WINDOW_SIZE;
    }

    if window_size > net_to_host_endian_32(command.connect.window_size) then window_size = net_to_host_endian_32(command.connect.window_size);

    if window_size < PROTOCOL_MIN_WINDOW_SIZE {
        window_size = PROTOCOL_MIN_WINDOW_SIZE;
    } else if window_size > PROTOCOL_MAX_WINDOW_SIZE {
        window_size = PROTOCOL_MAX_WINDOW_SIZE;
    }

    verify_cmd : Protocol;
    verify_cmd.header.command = Protocol_Command.VERIFY_CONNECT | .FLAG_ACKNOWLEDGE;
    verify_cmd.header.channel_id = 0xFF;
    verify_cmd.verify_connect.outgoing_peer_id = host_to_net_endian_16(peer.incoming_peer_id);
    verify_cmd.verify_connect.incoming_session_id = incoming_session_id;
    verify_cmd.verify_connect.outgoing_session_id = outgoing_session_id;
    verify_cmd.verify_connect.mtu = host_to_net_endian_32(peer.mtu);
    verify_cmd.verify_connect.window_size = host_to_net_endian_32(window_size);
    verify_cmd.verify_connect.channel_count = host_to_net_endian_32(channel_count);
    verify_cmd.verify_connect.incoming_bandwidth = host_to_net_endian_32(host.incoming_bandwidth);
    verify_cmd.verify_connect.outgoing_bandwidth = host_to_net_endian_32(host.outgoing_bandwidth);
    verify_cmd.verify_connect.packet_throttle_interval = host_to_net_endian_32(peer.packet_throttle_interval);
    verify_cmd.verify_connect.packet_throttle_acceleration = host_to_net_endian_32(peer.packet_throttle_acceleration);
    verify_cmd.verify_connect.packet_throttle_deceleration = host_to_net_endian_32(peer.packet_throttle_deceleration);
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

    if peer.state != .DISCONNECTED then peer.event_data = net_to_host_endian_32(command.disconnect.data);

    return .NONE;
}

protocol_handle_send_reliable :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **u8) -> Result_Status {
    if command.header.channel_id >= peer.channels.count || peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER {
        return .ERROR;
    }

    data_length := net_to_host_endian_16(command.send_reliable.data_length);
    current_data.* += data_length;

    if data_length > host.maximum_packet_size || current_data.* < host.received_data || current_data.* > *host.received_data[host.received_data_length] {
        return .ERROR;
    }

    if peer_queue_incoming_command(peer, command, cast(*u8)(command) + size_of(Protocol_Send_Reliable), data_length, .RELIABLE, 0) == null {
        return .ERROR;
    }

    return .NONE;
}

protocol_handle_send_unreliable :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **u8) -> Result_Status {
    if command.header.channel_id >= peer.channels.count || peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER return .ERROR;

    data_length := net_to_host_endian_16(command.send_unreliable.data_length);
    current_data.* += data_length;

    if data_length > host.maximum_packet_size || current_data.* < host.received_data || current_data.* > *host.received_data[host.received_data_length] {
        return .ERROR;
    }

    if peer_queue_incoming_command(peer, command, (cast(*u8)command) + size_of(Protocol_Send_Unreliable), data_length, 0, 0) == null then return .ERROR;

    return .NONE;
}

protocol_handle_send_unsequenced :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **u8) -> Result_Status {
    if command.header.channel_id >= peer.channels.count || (peer.state != .CONNECTED && peer.state != .DISCONNECT_LATER) return .ERROR;

    data_length := net_to_host_endian_16(command.send_unsequenced.data_length);
    current_data.* += data_length;
    
    if data_length > host.maximum_packet_size || current_data.* < host.received_data || current_data.* > *host.received_data[host.received_data_length] return .ERROR;

    unsequenced_group := cast(s64)net_to_host_endian_16(command.send_unsequenced.unsequenced_group);
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

    fragment_length := net_to_host_endian_16(command.send_fragment.data_length);
    current_data.* += fragment_length;

    if fragment_length > host.maximum_packet_size || current_data.* < host.received_data || current_data.* > *host.received_data[host.received_data_length] then return .ERROR;

    channel := *peer.channels[command.header.channel_id];
    start_seq_number := net_to_host_endian_16(command.send_fragment.start_seq_number);
    start_window := start_seq_number / PEER_RELIABLE_WINDOW_SIZE;
    current_window := channel.incoming_reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;

    if start_seq_number < channel.incoming_reliable_seq_number then start_window += PEER_RELIABLE_WINDOWS;

    if start_window < current_window || start_window >= current_window + PEER_FREE_RELIABLE_WINDOWS -1 then return .NONE;

    fragment_number := net_to_host_endian_32(command.send_fragment.fragment_number);
    fragment_count  := net_to_host_endian_32(command.send_fragment.fragment_count);
    fragment_offset := net_to_host_endian_32(command.send_fragment.fragment_offset);
    total_length    := net_to_host_endian_32(command.send_fragment.total_length);

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
        host_cmd := command.*;
        host_cmd.header.reliable_seq_number = start_seq_number;
        start_cmd = peer_queue_incoming_command(peer, *host_cmd, null, total_length, .RELIABLE, fragment_count);
        if start_cmd == null then return .ERROR;
    }

    if start_cmd.fragments[fragment_number / 32] & (1 << (fragment_number % 32)) == 0 {
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

    fragment_length := net_to_host_endian_16(command.send_fragment.data_length);
    current_data.* += fragment_length;

    if fragment_length > host.maximum_packet_size || current_data.* < host.received_data || current_data.* > *host.received_data[host.received_data_length] {
        return .ERROR;
    }

    channel := *peer.channels[command.header.channel_id];
    reliable_seq_number := command.header.reliable_seq_number;
    start_seq_number := net_to_host_endian_16(command.send_fragment.start_seq_number);

    reliable_window := reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;
    current_window := channel.incoming_reliable_seq_number / PEER_RELIABLE_WINDOW_SIZE;

    if reliable_seq_number < channel.incoming_reliable_seq_number then reliable_window += PEER_RELIABLE_WINDOWS;

    if reliable_window < current_window || reliable_window >= current_window + PEER_FREE_RELIABLE_WINDOWS - 1 then return .NONE;

    if reliable_seq_number == channel.incoming_reliable_seq_number && start_seq_number <= channel.incoming_unreliable_seq_number then return .NONE;

    fragment_number := net_to_host_endian_32(command.send_fragment.fragment_number);
    fragment_count  := net_to_host_endian_32(command.send_fragment.fragment_count);
    fragment_offset := net_to_host_endian_32(command.send_fragment.fragment_offset);
    total_length    := net_to_host_endian_32(command.send_fragment.total_length);

    // These giant ifs are terrible
    if fragment_count > PROTOCOL_MAX_FRAGMENT_COUNT ||
       fragment_number >= fragment_count ||
       total_length > host.maximum_packet_size ||
       fragment_offset > total_length ||
       fragment_length > total_length - fragment_offset then return .ERROR;

    start_cmd: *Incoming_Command;

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

    if start_cmd.fragments[fragment_number / 32] & (1 << (fragment_number % 32)) == 0 {
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

    peer.incoming_bandwidth = net_to_host_endian_32(command.bandwidth_limit.incoming_bandwidth);

    if peer.incoming_bandwidth != 0 then host.bandwidth_limited_peers += 1;

    peer.outgoing_bandwidth = net_to_host_endian_32(command.bandwidth_limit.outgoing_bandwidth);

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

    peer.packet_throttle_interval = net_to_host_endian_32(command.throttle_configure.packet_throttle_interval);
    peer.packet_throttle_acceleration = net_to_host_endian_32(command.throttle_configure.packet_throttle_acceleration);
    peer.packet_throttle_deceleration = net_to_host_endian_32(command.throttle_configure.packet_throttle_deceleration);

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
    } else if event {
        event.type = .DISCONNECT_TIMEOUT;
        event.peer = peer;
        event.data = 0;

        peer_reset(peer);
    } else {
        peer.event_data = 0;
        protocol_dispatch_state(host, peer, .ZOMBIE);
    }
}

list_begin :: inline (list: *List) -> *List_Node {
    return list.sentinel.next;
}

list_front :: inline (list: *List) -> *void {
    return list.sentinel.next;
}

list_end :: inline (list: *List) -> *List_Node {
    return *list.sentinel;
}

list_next :: inline (list: *List_Node) -> *List_Node {
    return list.next;
}

list_next :: inline (list: *List) -> *List_Node {
    return list.sentinel.next;
}

list_previous :: inline (list: *List) -> *List_Node {
    return list.sentinel.prev;
}

list_previous :: inline (list: *List_Node) -> *List_Node {
    return list.prev;
}

list_insert :: (position: *List_Node, data: *List_Node) -> List_Node {
    data.prev = position.prev;
    data.next = position;

    data.prev.next = data;
    position.prev = data;

    return data.*;
}

list_move :: (list: *List_Node, first: *List_Node, last: *List_Node) -> *List_Node {
    first.prev.next = last.next;
    last.next.prev = first.prev;

    first.prev = list.prev;
    last.next = list;

    first.prev.next = first;
    list.prev = last;

    return first;
}

list_remove :: (node: *List_Node) -> *void {
    node.prev.next = node.next;
    node.next.prev = node.prev;

    return node;
}

list_clear :: (list: *List) {
    list.sentinel.next = *list.sentinel;
    list.sentinel.prev = *list.sentinel;
}

list_empty :: (list: *List) -> bool {
    beg := list_begin(list);
    en := list_end(list);
    return  beg == en;
}

for_expansion :: (list: *List, body: Code, flags: For_Flags) #expand {
    `it := list_begin(list);
    `it_index := 0;
    while it != list_end(list) {
        defer it = list_next(it);
        defer it_index += 1;

        #insert body;
    }
}

reverse :: (list: *List, body: Code, flags: For_Flags) #expand {
    `it := list_previous(list_end(list));
    `it_index := 0;
    while it != list_end(list) {
        defer it = list_previous(it);
        defer it_index += 1;
        #insert body;
    }
}
