
renet :: #import "renet";

main :: () {

  if !renet.initialize() {
    print("Failed to initialize enet\n");
    return;
  }
  defer renet.deinitialize();

  // Server is created by assigning an address and port to bind to
  address : renet.Address;
  address.host = renet.HOST_ANY;
  address.port = 1234;

  host, success := renet.host_create(*address, 4, 1, 0, 0);

  if !success print("Failed to create server\n");

  renet.host_destroy(host);
}

#scope_file
#import "Basic";

