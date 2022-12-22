
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

    if !success print("Failed to create server\n");

    while true {
        event : enet.Event;

        print("servicing...\n");
        while enet.host_service(host, *event, 5000) > 0 {
            if event.type == {
                case;
                    print("Received event %\n", event.type);
            }
        }

        sleep_milliseconds(1600);
    }

    enet.host_destroy(host);
}

#scope_file
#import "Basic";
