# `libzev` - Cross platform event loop.

`libzev` is a cross platform event loop inspired by `io_uring`. It works using
2 fixed size ring buffers, one to submit I/O operations and one to retrieve
I/O completions.

It works as follow:
* You prepare I/O operations by adding them to the submission queue (SQ)
* You submit the SQ
* You wait for I/O completions to be added to the completion queue (CQ)
* You process the results

```
                             libzev                             
          +-----------------------------------------+           
         add                                     consume        
         I/O                                       I/O          
      operation         submit then poll        completion      
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
