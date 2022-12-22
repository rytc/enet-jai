
enet :: #import "enet";

main :: () {

    if !enet.initialize() {
        print("Failed to initialize enet\n");
        return;
    }
    defer enet.deinitialize();

    // Client is created by not binding to an address
    client, success := enet.host_create(null, 4, 1, 0, 0);

    if !success print("Failed to create client\n");

    address, success_ip := enet.get_host_ip_address("127.0.0.1");
    address.port = 1234;

    peer := enet.host_connect(client, *address, 2, 0); 

    while true {
        event : enet.Event;

        print("client servicing...\n");
        while enet.host_service(client, *event, 5000) > 0 {
            if event.type == {
                case;
                    print("Received event %\n", event.type);
            }
        }

        sleep_milliseconds(1600);
    }

    enet.host_destroy(client);
}

#scope_file
#import "Basic";

