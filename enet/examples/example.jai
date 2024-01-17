enet :: #import,dir "../../enet";
#import "Basic";

SERVER_ADDRESS :: "127.0.0.1";
SERVER_PORT :: 1234;
WAIT_FOR_PACKETS_MS :: 16;
MAX_CLIENTS :: 16;

main :: () {
    server: bool;
    args := get_command_line_arguments();
    for args {
        if it == "-server"
            server = true;
    }

    if !enet.initialize() {
        print("Failed to initialize enet\n");
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
        print("Failed to create server\n");
        return;
    }
    defer enet.host_destroy(host);

    print("Server started...\n");

    while true {
        event: enet.Event;
        while enet.host_service(host, *event, WAIT_FOR_PACKETS_MS) == .SUCCESS {
            sender_address := ifx event.peer != null then address_to_string(event.peer.address) else copy_string("UNKNOWN");
            defer free(sender_address);

            if event.type == {
                case .CONNECT;
                    print("Connected client % on connection %\n", sender_address, event.peer.connect_id);

                case .RECEIVE;
                    msg: string = .{event.packet.data_length, event.packet.data};
                    print("Server recieved message \"%\" on connection %\n", msg, event.peer.connect_id);
                    enet.packet_destroy(event.packet);

                case .DISCONNECT;
                    print("Disconnected client % on connection %\n", sender_address, event.peer.connect_id);

                case .DISCONNECT_TIMEOUT; 
                    print("Disconnected (timeout) client % on connection %\n", sender_address, event.peer.connect_id);

                case;
                    print("Received event %\n", event.type);
            }
        }

        for * peer: host.peers {
            if peer.state == .CONNECTED {
                msg := sprint("This is connection %", peer.connect_id);
                defer free(msg);
                packet := enet.packet_create(msg.data, msg.count, .RELIABLE);
                enet.peer_send(peer, 0, packet);
            }
        }
    }
}

run_client :: () {
    log("Running as CLIENT");

    client, success := enet.host_create(null, 1, 10, 0, 0);
    if !success { 
        print("Failed to create client\n");
        return;
    }
    defer enet.host_destroy(client);

    address := enet.get_host_ip_address(SERVER_ADDRESS);
    address.port = SERVER_PORT;

    print("Connecting to server %:%\n", SERVER_ADDRESS, SERVER_PORT);
    server := enet.host_connect(client, *address, 1, 5);

    disconnect_countdown := 10;

    connected := false;

    while running := true {
        event: enet.Event;
        while enet.host_service(client, *event, WAIT_FOR_PACKETS_MS) == .SUCCESS {
            if event.type == {
                case .CONNECT;
                    print("Connected to server via connection %\n", event.peer.connect_id);
                    connected = true;

                case .RECEIVE;
                    msg: string = .{event.packet.data_length, event.packet.data};
                    print("Client recieved message \"%\" on connection %\n", msg, event.peer.connect_id);
                    enet.packet_destroy(event.packet);

                case .DISCONNECT;
                    print("Connection % disconnected\n", event.peer.connect_id);
                    break running;

                case .DISCONNECT_TIMEOUT;
                    print("Connection % disconnected (timeout)\n", event.peer.connect_id);
                    break running;

                case;
                    print("Received event %\n", event.type);
            }
        }

        if connected {
            if disconnect_countdown > 0 {
                msg := sprint("Client on connection % will disconnect in %", server.connect_id, disconnect_countdown);
                defer free(msg);
                packet := enet.packet_create(msg.data, msg.count, .RELIABLE);
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
