
enet :: #import "enet";

main :: () {

    if !enet.initialize() {
        print("Failed to initialize enet\n");
        return;
    }
    defer enet.deinitialize();

    channel_count := 2;

    // Client is created by not binding to an address
    client, success := enet.host_create(null, 4, channel_count, 0, 0);

    if !success { 
        print("Failed to create client\n");
        return;
    }

    defer enet.host_destroy(client);

    // To get an address by domain name, use get_host_name_address("my.domain.co")
    address := enet.get_host_ip_address("127.0.0.1");
    address.port = 1234;

    peer := enet.host_connect(client, *address, channel_count, 0); 

    msg := "The fox jumped over the lazy dog";
    packet := enet.packet_create(msg.data, msg.count, .RELIABLE);

    msg2 := "The UNRELIABLE fox jumped over the lazy dog";
    packet_unreliable := enet.packet_create(msg2.data, msg2.count, .UNRELIABLE_FRAGMENT);

    send_msg := 0;

    while true {
        event : enet.Event;

        while enet.host_service(client, *event, 0) > 0 {
            if event.type == {
                case .CONNECT;
                    print("!! Connected to server. Sending a secret message.\n");
                    send_msg += 1;
                case;
                    print("!! Received event %\n", event.type);
            }
        }

        if send_msg == 1 {
            enet.peer_send(peer, 0, packet);
            send_msg += 1;
        } else if send_msg == 2 {
            enet.peer_send(peer, 0, packet_unreliable);
            send_msg += 1;
        }

        sleep_milliseconds(16);
    }

}

#scope_file
#import "Basic";

