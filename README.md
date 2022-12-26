
This is a native Jai port (no c libraries needed, aside from the OS sockets) of the ENet reliable UDP networking library. Specifically this is of the zpl-c version that supports IPv6 and other features.

### Current state

All ENet functionality is implemented, however it is not thoroughly tested.

### What is ENet?
> ENet evolved specifically as a UDP networking layer for the multiplayer first person shooter Cube.
> 
> Cube necessitated low latency communication with data sent out very frequently, so TCP was an unsuitable choice due to its high latency and stream orientation. UDP, however, lacks many sometimes necessary features from TCP such as reliability, sequencing, unrestricted packet sizes, and connection management. So UDP by itself was not suitable as a network protocol either. No suitable freely available networking libraries existed at the time of ENet's creation to fill this niche.
>
> UDP and TCP could have been used together in Cube to benefit somewhat from both of their features, however, the resulting combinations of protocols still leaves much to be desired. TCP lacks multiple streams of communication without resorting to opening many sockets and complicates delineation of packets due to its buffering behavior. UDP lacks sequencing, connection management, management of bandwidth resources, and imposes limitations on the size of packets. A significant investment is required to integrate these two protocols, and the end result is worse off in features and performance than the uniform protocol presented by ENet.
> 
> ENet thus attempts to address these issues and provide a single, uniform protocol layered over UDP to the developer with the best features of UDP and TCP as well as some useful features neither provide, with a much cleaner integration than any resulting from a mixture of UDP and TCP.

### Links

- ENet zpl-c fork https://github.com/zpl-c/enet
- ENet original https://github.com/lsalzman/enet
- ENet site http://enet.bespin.org/

