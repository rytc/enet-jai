
// @TODO make sure time functionality is ok...
// Not sure if I should store apollo time or just to_milliseconds(current_time_monotonic())

HOST_ANY :: V6_ANY_ADDR;

Address :: struct {
    host : in6_addr;
    port : u16;
    sin6_scope_id : u16;
}

Channel :: struct {
    outgoing_reliable_seq_number : u16;
    outgoing_unreliable_seq_number : u16;
    used_reliable_windows : type_of(PEER_RELIABLE_WINDOWS); 
    reliable_windows : [PEER_RELIABLE_WINDOWS] u16;
    incoming_reliable_seq_number : u16;
    incoming_unreliable_seq_number : u16;
    incoming_reliable_commands : List;
    incoming_unreliable_commands : List;
}

Packet_Flags :: enum_flags u16 {
    RELIABLE;
    UNSEQUENCED;
    NO_ALLOCATE;
    UNRELIABLE_FRAGMENT;
    SENT;
}

Packet :: struct {
    ref_count : u32;
    flags : Packet_Flags;
    data : *u8;
    data_length: u32;
    user_data : *Any;
}

initialize :: () -> bool {
    #if OS == .WINDOWS {
        version : u16 = (1 << 8) | 1;
        wsa_data : WSAData;

        if WSAStartup(version, *wsa_data) {
            log_error("Failed to initialize enet: Failed to startup WSA\n");
            return false;
        }

        if wsa_data.wVersion & 1 != 1 || wsa_data.wVersion >> 8 != 1 {
            log_error("Failed to initialize enet: Requested WSA version is % but got %\n", version, wsa_data.wVersion);
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

create_packet :: (data: *$T, flags: Packet_Flags = .RELIABLE) -> *Packet #expand {
    return create_packet(xx data, xx size_of(T), flags);
}

create_packet :: (data: []u8, flags: Packet_Flags = .RELIABLE) -> *Packet #expand {
    return create_packet(xx data.data, xx data.count, flags);
}

destroy_packet :: (packet: *Packet) {
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


create_packet :: (data : *void, data_length : u32, flags : Packet_Flags = .RELIABLE) -> *Packet {
    packet : *Packet;

    // @TODO :alloc better allocation strategy?
    if flags & .NO_ALLOCATE {
        packet = New(Packet);
        packet.data = xx data;
    } else {
        packet = alloc(size_of(Packet) + data_length);
        packet.data = cast(*u8)(packet) + size_of(Packet);
        memcpy(packet.data, data, data_length);
    }

    packet.flags = flags;
    packet.data_length = data_length;

    return packet;
}

#load "host.jai";
#load "peer.jai";

#scope_module
#import "Basic";
#import "Socket";
#load "protocol.jai";
#load "socket.jai";

start_time : Apollo_Time;

V6_ANY_ADDR :: in6_addr.{.{.[ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ]}};
V6_NO_ADDR :: in6_addr.{.{.[ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff ]}};

#if OS == .WINDOWS {
    MAX_BUFFER_COUNT :s32: cast(s32)MSG.MSG_MAXIOVLEN;
} else {
    MAX_BUFFER_COUNT :: 1 + 2 * PROTOCOL_MAX_PACKET_COMMANDS; 
}


List_Node :: struct {
    prev : *List_Node;
    next : *List_Node;
}

List :: struct {
    sentinel : List_Node;
}

list_begin :: (list: *List) -> *List_Node #expand {
    return list.sentinel.next;
}

list_front :: (list: *List) -> *void #expand {
    return list.sentinel.next;
}

list_end :: (list: *List) -> *List_Node #expand {
    return *list.sentinel;
}

list_next :: (list: *List_Node) -> *List_Node #expand {
    return list.next;
}

list_next :: (list: *List) -> *List_Node #expand {
    return list.sentinel.next;
}

list_insert :: (position: *List_Node, data: *List_Node) -> List_Node {
    data.prev = position.prev;
    data.next = position;

    data.prev.next = data;
    position.prev = data;

    return <<data;
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

// @TODO this doesn't need to be a pointer...
list_empty :: (list: *List) -> bool {
    return list_begin(list) == list_end(list);
}

Buffer :: struct {
    length : s64;
    data : *void;
}

Acknowledgement :: struct {
    #as using list : List_Node;
    sent_time: s64; // :Time
    command : Protocol;
}

Command :: struct {
    #as using list : List_Node;
    packet : *Packet;
}

Incoming_Command :: struct {
    #as using base : Command;
}

Outgoing_Command :: struct {
    #as using base : Command;
    reliable_seq_number : u16;
    unreliable_seq_number : u16;
    sent_time : u32;
    round_trip_timeout : s64;
    round_trip_timeout_limit : s64;
    fragment_offset : u32;
    fragment_length : u16;
    send_attempts : u16;
    command : Protocol;
    timeout_maximum : s64; // :Time
}

Event_Type :: enum {
    NONE;
    CONNECT;
    DISCONNECT;
    RECEIVE;
    DISCONNECT_TIMEOUT;
}

Event :: struct {
    type : Event_Type;
    peer : *Peer;
    channel_id : u8;
    data : u32;
    packet : *Packet;
}

random_seed :: () -> u64 {
    #if OS == .WINDOWS {
        return cast(u64)Windows.timeGetTime();
    } else {
        return cast(u64)time(null);
    }
}

lookup_host :: (name: string, no_dns: bool) -> Address, bool {
    hints : addrinfo;
    result_list : *addrinfo;
    result : *addrinfo;
    result_address : Address;

    hints.ai_family = AF_UNSPEC;

    if no_dns hints.ai_flags = .NUMERICHOST;

    hostname := temp_c_string(name);
    if getaddrinfo(hostname, null, *hints, *result_list) != 0 {
        freeaddrinfo(result_list);
        return result_address, false;
    }

    defer freeaddrinfo(result_list);

    result = result_list;
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

    result : in6_addr;
    result.u.Byte[10] = 0xFF;
    result.u.Byte[11] = 0xFF;
    result.u.Byte[12] = (cast(*u8)*addr.S_un.S_addr)[0];
    result.u.Byte[13] = (cast(*u8)*addr.S_un.S_addr)[1];
    result.u.Byte[14] = (cast(*u8)*addr.S_un.S_addr)[2];
    result.u.Byte[15] = (cast(*u8)*addr.S_un.S_addr)[3];

    return result;
}

map_ip4_to_ip6 :: (addr: in6_addr) -> in_addr {
    result : in_addr;
    result.S_addr[0] = (cast(*u8)*addr.S_addr)[0];
    result.S_addr[1] = (cast(*u8)*addr.S_addr)[1];
    result.S_addr[2] = (cast(*u8)*addr.S_addr)[2];
    result.S_addr[3] = (cast(*u8)*addr.S_addr)[3];

    return result;
}

host_to_net_endian :: (value: u16 ) -> u16 #expand {
    return htons(value);
}

host_to_net_endian :: (value: u32) -> u32 #expand {
    return htonl(value);
}

net_to_host_endian :: (value: u16) -> u16 #expand {
    return ntohs(value);
}

net_to_host_endian :: (value: u32) -> u32 #expand {
    return ntohl(value);
}

in6_equal ::(a: in6_addr, b: in6_addr) -> bool #expand {
    return memcmp(*a, *b, size_of(in6_addr)) == 0;
}

#scope_file
#import "Math"; // U32_MAX

#if OS == .WINDOWS {
    Windows :: #import "Windows"; // timeGetTime
}


