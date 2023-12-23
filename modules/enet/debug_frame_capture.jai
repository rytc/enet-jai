MAX_FRAME_CAPTURE_COUNT :: 60;

Frame_Data :: struct {
    frame_number: u64;
    packets_sent_count: int;
    packets_received_count: int;

    errors: [..]Frame_Error;
}

frame_captures: [MAX_FRAME_CAPTURE_COUNT]Frame_Data;
frame_capture_count := 0;

Error_Type :: enum {
    ERROR_SENDING_PACKET;
}

Frame_Error :: struct {
    type: Error_Type;
    union {
        send_packet_error: Error_Sending_Packet;
    }
}

Error_Sending_Packet :: struct {
    peer_id: u16;
    peer_state: Peer_State;
    reported_sent_size: int;
    socket_error: int;
}

debug_set_allocator :: (allocator: Allocator) {
    if !frame_allocator_set {
        frame_allocator = allocator;

        for * frame: frame_captures {
            init_frame(frame);
        }
        frame_allocator_set = true;
    } else {
        log_error("ENet Debug Frame Capture: Cannot set allocator after one has already been set!");
    }
}

debug_start_capturing :: () {
    capturing = true;
    capture_index = 0;
    frame_capture_count = 0;
}

debug_stop_capturing :: () {
    capturing = false;
}

#scope_module

debug_begin_frame :: () {
    if capturing {
        capture_index = (capture_index + 1) % MAX_FRAME_CAPTURE_COUNT;
        current_frame = *frame_captures[capture_index];
        reset_frame(current_frame);
        current_frame.frame_number = current_frame_number;
    }
}

debug_end_frame :: () {
    if capturing && frame_capture_count < 60 frame_capture_count += 1;
    current_frame_number += 1;
}

debug_error_sending_packet :: (peer_id: u16, peer_state: Peer_State, reported_sent_size: int, socket_error: int) {
    err := Frame_Error.{
        type = .ERROR_SENDING_PACKET,
        send_packet_error = .{
            peer_id = peer_id,
            peer_state = peer_state,
            reported_sent_size = reported_sent_size,
            socket_error = socket_error
        }
    };
    if capturing array_add(*current_frame.errors, err);
}

debug_increment_packets_sent :: inline () {
    if capturing current_frame.packets_sent_count += 1;
}

debug_increment_packets_received :: inline () {
    if capturing current_frame.packets_received_count += 1;
}

#scope_file

frame_allocator_set := false;
frame_allocator: Allocator;

current_frame_number :u64= 0;
current_frame: *Frame_Data;
capture_index := 0;
capturing := false;

init_frame :: (frame: *Frame_Data) {
    frame.errors.allocator = frame_allocator;
}

reset_frame :: (frame: *Frame_Data) {
    frame.errors.count = 0;
    frame.packets_sent_count = 0;
    frame.packets_received_count = 0;
}

