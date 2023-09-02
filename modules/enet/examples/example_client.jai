
main :: () {
    if !enet.initialize() {
        print("Failed to initialize enet\n");
        return;
    }
    defer enet.deinitialize();

    channel_count := 2;

    // Client is created by not binding to an address
    client, success := enet.host_create(null, 1, channel_count, 0, 0);

    if !success { 
        print("Failed to create client\n");
        return;
    }

    defer enet.host_destroy(client);

    running := true;

    // To get an address by domain name, use get_host_name_address("my.domain.co")
    address := enet.get_host_ip_address(SERVER_ADDRESS);
    address.port = SERVER_PORT;

    print("Connecting to server %:%\n", SERVER_ADDRESS, SERVER_PORT);
    peer := enet.host_connect(client, *address, channel_count, 0); 

    msg := "The fox jumped over the lazy dog";
    msg2 := "The UNRELIABLE fox jumped over the lazy dog";

    counter := 0;

    while running {
        event : enet.Event;

        while enet.host_service(client, *event, 0) == .SUCCESS {
            if event.type == {
                case .CONNECT;
                    print("Connected to server. Sending a secret message.\n");
                    counter += 1;
                case .DISCONNECT; #through;
                case .DISCONNECT_TIMEOUT;
                    print("Disconnected: %\n", event.type);
                    running = false;
                    break;
                case;
                    print("Received event %\n", event.type);
            }
        }

        if counter == {
            case 1;
                // The module will free the packet once it gets sent, so a new packet needs to be created every time
                packet := enet.packet_create(msg.data, msg.count, .RELIABLE);
                enet.peer_send(peer, 0, packet);
            case 2; 
                packet_unreliable := enet.packet_create(msg2.data, msg2.count, .UNRELIABLE_FRAGMENT);
                enet.peer_send(peer, 0, packet_unreliable);
            case 100; // Have to give enough time for both packets to send
                enet.peer_disconnect(peer, 0);
        }

        if counter > 0 {
            counter += 1;
        }

    }
}

#scope_file
#import "Basic";
enet :: #import "enet";

SERVER_ADDRESS :: "127.0.0.1";
SERVER_PORT    :: 1234;

