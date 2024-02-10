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

        command_number : Protocol_Command;
        start_seq_number : u16;

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
        
        enet_peer_queue_outgoing_command(peer, *command, null, 0, 0);
        enet_host_flush(peer.host);
    }

    peer_reset(peer);
}

peer_disconnect_later :: (peer: *Peer, data: u32) {
    if peer.state == .CONNECTED || peer.state == .DISCONNECT_LATER &&
       (!list_empty(*peer.outgoing_reliable_commands) &&
        list_empty(*peer.outgoing_unreliable_commands) &&
        list_empty(peer.sent_reliable_commands)) {

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

    peer_queue_outgoing_command(peer, *command, null, 0, 0);
}

peer_ping_interval :: (peer: *Peer, interval: u32) {
    peer.ping_interval = ifx ping_interval then ping_interval else PEER_PING_INTERVAL;
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
        outgoing_session_id = peer.outgoing_session_id,
        incoming_session_id = peer.incoming_session_id,
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

#scope_module

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
PEER_PING_INTERVAL                :: 800;
PEER_PACKET_THROTTLE_COUNTER      :: 7;
PEER_UNSEQUENCED_WINDOW_SIZE      :: 1024;
PEER_UNSEQUENCED_WINDOWS          :: 64;
PEER_FREE_UNSEQUENCED_WINDOWS     :: 32;

DUMMY_COMMAND: Incoming_Command; 

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

