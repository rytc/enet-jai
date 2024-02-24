// Run "example.exe -server" to run as server, then run a second instance to connect as a client.
enet :: #import,file "../enet.jai";
#import "Basic";

SERVER_ADDRESS :: "127.0.0.1";
SERVER_PORT :: 1234;
WAIT_FOR_PACKETS_MS :: 0;
MAX_CLIENTS :: 16;

main :: () {
    server: bool;
    args := get_command_line_arguments();
    for args {
        if it == "-server"
            server = true;
    }

    if !enet.initialize() {
        log_error("Failed to initialize enet");
        return;
    }
    defer enet.deinitialize();

    if server
        run_server();
    else
        run_client();
}

run_server :: () {
    log("Running as SERVER");

    address: enet.Address;
    address.host = enet.HOST_ANY;
    address.port = SERVER_PORT;

    host, success := enet.host_create(*address, MAX_CLIENTS, 10, 0, 0);
    if !success {
        log_error("Failed to create server");
        return;
    }
    defer enet.host_destroy(host);

    log("Server started...");

    while true {
        event: enet.Event;
        while enet.host_service(host, *event, WAIT_FOR_PACKETS_MS) == .SUCCESS {
            sender_address := ifx event.peer != null then address_to_string(event.peer.address) else copy_string("UNKNOWN");
            defer free(sender_address);

            if event.type == {
                case .CONNECT;
                    log("Connected client % on connection %", sender_address, event.peer.connect_id);

                case .RECEIVE;
                    msg: string = .{event.packet.data_length, event.packet.data};
                    log("Server recieved message \"%\" on connection %", msg, event.peer.connect_id);
                    enet.packet_destroy(event.packet);

                case .DISCONNECT;
                    log("Disconnected client % on connection %", sender_address, event.peer.connect_id);

                case .DISCONNECT_TIMEOUT;
                    log("Disconnected (timeout) client % on connection %", sender_address, event.peer.connect_id);

                case;
                    log("Received event %", event.type);
            }
        }

        for * peer: host.peers {
            if peer.state == .CONNECTED {
                msg := sprint("This is connection %", peer.connect_id);
                defer free(msg);
                packet := enet.packet_create(msg.data, msg.count, .UNRELIABLE_FRAGMENT);
                enet.peer_send(peer, 0, packet);
            }
        }
    }
}

run_client :: () {
    log("Running as CLIENT");

    client, success := enet.host_create(null, 1, 10, 0, 0);
    if !success {
        log_error("Failed to create client");
        return;
    }
    defer enet.host_destroy(client);

    address := enet.get_host_ip_address(SERVER_ADDRESS);
    address.port = SERVER_PORT;

    log("Connecting to server %:%", SERVER_ADDRESS, SERVER_PORT);
    server := enet.host_connect(client, *address, 1, 5);

    disconnect_countdown := 10;

    connected := false;

    while running := true {
        event: enet.Event;
        while enet.host_service(client, *event, WAIT_FOR_PACKETS_MS) == .SUCCESS {
            if event.type == {
                case .CONNECT;
                    log("Connected to server via connection %", event.peer.connect_id);
                    connected = true;

                case .RECEIVE;
                    msg: string = .{event.packet.data_length, event.packet.data};
                    log("Client recieved message \"%\" on connection %", msg, event.peer.connect_id);
                    enet.packet_destroy(event.packet);

                case .DISCONNECT;
                    log("Connection % disconnected", event.peer.connect_id);
                    break running;

                case .DISCONNECT_TIMEOUT;
                    log("Connection % disconnected (timeout)", event.peer.connect_id);
                    break running;

                case;
                    log("Received event %", event.type);
            }
        }

        if connected {
            if disconnect_countdown > 0 {
                msg := sprint("Client on connection % will disconnect in %", server.connect_id, disconnect_countdown);
                defer free(msg);
                packet := enet.packet_create(msg.data, msg.count, .UNRELIABLE_FRAGMENT);
                enet.peer_send(server, 0, packet);
            } else {
                enet.peer_disconnect(server, 0);
            }
            disconnect_countdown -= 1;
        }
    }
}

address_to_string :: (address : enet.Address) -> string {
    Socket :: #import "Socket";
    addr : Socket.sockaddr_in6;
    addr.sin6_port = address.port;
    addr.sin6_addr = address.host;
    addr.sin6_scope_id = address.sin6_scope_id;
    return Socket.to_string(addr);
}
