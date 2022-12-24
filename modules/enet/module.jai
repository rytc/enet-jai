
// @TODO make sure time functionality is ok...
// Not sure if I should store apollo time or just to_milliseconds(current_time_monotonic())
// ...
// I think it might be better to store milliseconds. Make a get time procedure that does to milliseconds,
// because we end up calling to_milliseconds every time we want to use/compare the host time to packet data
// and this might be slow
//

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
    host          : in6_addr;
    port          : u16;
    sin6_scope_id : u16;
}

Packet :: struct {
    ref_count   :  u32;
    flags       :  Packet_Flags;
    data        : *u8;
    data_length :  u32;
    user_data   : *Any;
}

Event :: struct {
    type       : Event_Type;
    peer       : *Peer;
    channel_id : u8;
    data       : u32;
    packet     : *Packet;
}

initialize :: () -> bool {
    #if OS == .WINDOWS {
        version :u16= (1 << 8) | 1;
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


packet_create :: (data: *$T, flags: Packet_Flags = .RELIABLE) -> *Packet #expand {
    return packet_create(cast(*void)data, size_of(T), flags);
}

packet_create :: (data: []u8, flags: Packet_Flags = .RELIABLE) -> *Packet #expand {
    return packet_create(cast(*void)data.data, data.count, flags);
}

packet_create :: (data : *void, data_length : int, flags : Packet_Flags = .RELIABLE) -> *Packet {
    packet : *Packet;

    assert(data_length >= 0 && data_length <= U32_MAX);

    if flags & .NO_ALLOCATE {
        packet = New(Packet);
        packet.data = xx data;
    } else {
        packet = alloc(size_of(Packet) + data_length);
        packet.data = cast(*u8)(packet) + size_of(Packet);
        memcpy(packet.data, data, cast(u32)data_length);
    }

    packet.flags = flags;
    packet.data_length = cast(u32)data_length;

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

#load "host.jai";
#load "peer.jai";

#scope_module
#import "Basic";
#import "Socket";
#load "protocol.jai";
#load "socket.jai";
#load "list.jai";

start_time : Apollo_Time;

V6_ANY_ADDR :: in6_addr.{.{.[ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ]}};
V6_NO_ADDR  :: in6_addr.{.{.[ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff ]}};

#if OS == .WINDOWS {
    MAX_BUFFER_COUNT :s32: cast(s32)MSG.MSG_MAXIOVLEN;
} else {
    MAX_BUFFER_COUNT :: 1 + 2 * PROTOCOL_MAX_PACKET_COMMANDS; 
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

// Should match WSABUF
Buffer :: struct {
    length : u32;
    data   : *void;
}

Acknowledgement :: struct {
    #as using list : List_Node;
    sent_time      : u32; // :Time
    command        : Protocol;
}

Command :: struct {
    #as using list : List_Node;
    packet         : *Packet;
}

Incoming_Command :: struct {
    #as using base        : Command;
    reliable_seq_number   : u16;
    unreliable_seq_number : u16;
    command               : Protocol;
    fragment_count        : u32;
    fragments_remaining   : u32;
    fragments             : []u32;
}

Outgoing_Command :: struct {
    #as using base           : Command;
    reliable_seq_number      : u16;
    unreliable_seq_number    : u16;
    sent_time                : u32;
    round_trip_timeout       : s64;
    round_trip_timeout_limit : s64;
    fragment_offset          : u32;
    fragment_length          : u16;
    send_attempts            : u16;
    command                  : Protocol;
}

random_seed :: () -> u64 {
    #if OS == .WINDOWS {
        return cast(u64)Windows.timeGetTime();
    } else {
        return cast(u64)time(null);
    }
}

lookup_host :: (name: string, no_dns: bool) -> Address, bool {
    result_list : *addrinfo;
    result_address : Address;

    hints : addrinfo;
    hints.ai_family = AF_UNSPEC;

    if no_dns hints.ai_flags = .NUMERICHOST;

    hostname := temp_c_string(name);
    if getaddrinfo(hostname, null, *hints, *result_list) != 0 {
        freeaddrinfo(result_list);
        return result_address, false;
    }

    defer freeaddrinfo(result_list);

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


