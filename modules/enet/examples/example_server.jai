
enet :: #import "enet";

main :: () {

    if !enet.initialize() {
        print("Failed to initialize enet\n");
        return;
    }
    defer enet.deinitialize();

    // Server is created by assigning an address and port to bind to
    address : enet.Address;
    address.host = enet.HOST_ANY;
    address.port = 1234;

    host, success := enet.host_create(*address, 4, 1, 0, 0);

    if !success {
        print("Failed to create server\n");
        return;
    }

    defer enet.host_destroy(host);

    while true {
        event : enet.Event;

        while enet.host_service(host, *event, 0) > 0 {
            if event.type == {
                case .CONNECT;
                    print("A client has connected!\n");
                case .RECEIVE;
                    msg : string;
                    msg.count = event.packet.data_length;
                    msg.data = event.packet.data;
                    print("We received a message! The message says \"%\"\n", msg); 
                    enet.packet_destroy(event.packet);
                case;
                    print("Received event %\n", event.type);
            }
        }

        sleep_milliseconds(16);
    }
}

#scope_file
#import "Basic";

