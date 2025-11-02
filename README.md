# `libzev` - Cross platform event loop.

`libzev` is a low level cross platform event loop inspired by `io_uring`.

It works as follow:
* You queue I/O operations
* You submit I/O operations in submission queue (SQ)
* You poll for completed operations in completion queue (CQ) and callbacks are
executed

```
                             libzev                             
          +-----------------------------------------+           
        queue                                     poll          
         I/O                                       I/O          
      operation              submit             completion      
+-----+   |    +----+        +----+        +----+   |    +-----+
| App +---|--->| SQ +------->| Io +------->| CQ +---|--->| App |
+-----+   |    +----+        +----+        +----+   |    +-----+
          |                                         |           
          +-----------------------------------------+           
```

## Goals

My goal for `libzev` is to produce a production-quality, permissively licensed,
`io_uring` like event loop library for Zig and C. It's main purpose is to enable
__parallelized I/O__ with a focus on __usability__ and __correctness__.

## Contributing

If you want to contribute to `libzev` to add a feature or improve the code
contact me at [alexandre@negrel.dev](mailto:alexandre@negrel.dev), open an
[issue](https://github.com/negrel/libzev/issues) or make a
[pull request](https://github.com/negrel/libzev/pulls).

## :stars: Show your support

Please give a :star: if this project helped you!

[![buy me a coffee](https://github.com/negrel/.github/blob/master/.github/images/bmc-button.png?raw=true)](https://www.buymeacoffee.com/negrel)

## :scroll: License

MIT © [Alexandre Negrel](https://www.negrel.dev/)
