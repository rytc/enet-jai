
renet :: #import "renet";

main :: () {

  if !renet.initialize() {
    print("Failed to initialize enet\n");
    return;
  }
  defer renet.deinitialize();

  // Client is created by not binding to an address
  client, success := renet.host_create(null, 4, 1, 0, 0);

  if !success print("Failed to create client\n");

  address, success_ip := renet.get_host_ip_address("127.0.0.1");
  address.port = 1234;

  peer := renet.host_connect(client, *address, 2, 0); 

  while true {
    event : renet.Event;
    while renet.host_service(client, *event, 5000) > 0 {
      if event.type == {
        case;
          print("Received event %\n", event.type);
      }
    }

    sleep_milliseconds(1600);
  }

  renet.host_destroy(client);
}

#scope_file
#import "Basic";

