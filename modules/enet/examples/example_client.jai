
enet :: #import "enet";

main :: () {

    if !enet.initialize() {
        print("Failed to initialize enet\n");
        return;
    }
    defer enet.deinitialize();

    channel_count :u32= 2;

    // Client is created by not binding to an address
    client, success := enet.host_create(null, 4, channel_count, 0, 0);

    if !success print("Failed to create client\n");

    address, success_ip := enet.get_host_ip_address("127.0.0.1");
    address.port = 1234;

    peer := enet.host_connect(client, *address, channel_count, 0); 

    while true {
        event : enet.Event;

        while enet.host_service(client, *event, 1000) > 0 {
            if event.type == {
                case;
                    print("!! Received event %\n", event.type);
            }
        }

        sleep_milliseconds(16);
    }

    enet.host_destroy(client);
}

#scope_file
#import "Basic";

