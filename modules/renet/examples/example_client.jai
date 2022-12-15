
enet :: #import "renet";

main :: () {

  if !renet.initialize() {
    print("Failed to initialize enet\n");
    return;
  }
  defer renet.deinitialize();

  // Client is created by not binding to an address
  host, success := renet.host_create(null, 4, 1, 0, 0);

  if !success print("Failed to create client\n");



  renet.host_destroy(host);
}

#scope_file
#import "Basic";

