
List_Node :: struct {
    prev : *List_Node;
    next : *List_Node;
}

List :: struct {
    sentinel : List_Node;
}

list_begin :: (list: *List) -> *List_Node #expand {
    return list.sentinel.next;
}

list_front :: (list: *List) -> *void #expand {
    return list.sentinel.next;
}

list_end :: (list: *List) -> *List_Node #expand {
    return *list.sentinel;
}

list_next :: (list: *List_Node) -> *List_Node #expand {
    return list.next;
}

list_next :: (list: *List) -> *List_Node #expand {
    return list.sentinel.next;
}

list_previous :: (list: *List) -> *List_Node #expand {
    return list.sentinel.prev;
}

list_previous :: (list: *List_Node) -> *List_Node #expand {
    return list.prev;
}

list_insert :: (position: *List_Node, data: *List_Node) -> List_Node {
    data.prev = position.prev;
    data.next = position;

    data.prev.next = data;
    position.prev = data;

    return <<data;
}

list_move :: (list: *List_Node, first: *List_Node, last: *List_Node) -> *List_Node {
    first.prev.next = last.next;
    last.next.prev = first.prev;

    first.prev = list.prev;
    last.next = list;

    first.prev.next = first;
    list.prev = last;

    return first;
}

list_remove :: (node: *List_Node) -> *void {
    node.prev.next = node.next;
    node.next.prev = node.prev;

    return node;
}

list_clear :: (list: *List) {
    list.sentinel.next = *list.sentinel;
    list.sentinel.prev = *list.sentinel;
}

list_empty :: (list: *List) -> bool {
    beg := list_begin(list);
    en := list_end(list);
    return  beg == en;
}


for_expansion :: (list: *List, body: Code, flags: For_Flags) #expand {
    `it := list_begin(list);
    `it_index := 0;
    while it != list_end(list) {
        defer it = list_next(it);
        defer it_index += 1;

        #insert body;
    }
}

