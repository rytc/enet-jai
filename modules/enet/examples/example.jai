enet :: #import "enet";
#import "Basic";

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

    host, success := enet.host_create(*address, 16, 10, 0, 0);
    if !success {
        print("Failed to create server\n");
        return;
    }
    defer enet.host_destroy(host);
    msg := "HELLO WORLD";

    print("Server started...\n");

    while true {
        event: enet.Event;
        while enet.host_service(host, *event, 2) == .SUCCESS {
            if event.type == {
                case .CONNECT;
                    print("A client has connected!\n");
                case .RECEIVE;
                    msg: string;
                    msg.count = event.packet.data_length;
                    msg.data = event.packet.data;
                    print("Message of length % received: \"%\"\n", event.packet.data_length, msg); 
                    enet.packet_destroy(event.packet);
                case .DISCONNECT; #through;
                case .DISCONNECT_TIMEOUT; 
                    print("A client has disconnected. %\n", event.type);
                case;
                    print("Received event %\n", event.type);
            }
        }

        for * peer: host.peers {
            if peer.state == .CONNECTED {
                packet := enet.packet_create(msg.data, msg.count, .RELIABLE);
                enet.peer_send(peer, 0, packet);
            }
        }

        sleep_milliseconds(16);
    }
}


SERVER_ADDRESS :: "127.0.0.1";
SERVER_PORT :: 1234;

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
    peer := enet.host_connect(client, *address, 1, 5); 

    msg := "HELLO WORLD 1 2 3 4 ";
    connected := false;

    while true {
        event: enet.Event;
        while enet.host_service(client, *event, 2) == .SUCCESS {
            if event.type == {
                case .CONNECT;
                    print("Connected to server.\n");
                    connected = true;
                case .RECEIVE;
                    msg: string;
                    msg.count = event.packet.data_length;
                    msg.data  = event.packet.data;
                    print("Message of length % received: \"%\"\n", event.packet.data_length, msg); 
                    enet.packet_destroy(event.packet);
                case .DISCONNECT; #through;
                case .DISCONNECT_TIMEOUT;
                    print("Disconnected: %\n", event.type);
                    exit(0);

                case;
                    print("Received event %\n", event.type);
            }
        }

        if connected {
            packet := enet.packet_create(msg.data, msg.count, .RELIABLE);
            enet.peer_send(peer, 0, packet);
        }
        sleep_milliseconds(16);
    }
}

