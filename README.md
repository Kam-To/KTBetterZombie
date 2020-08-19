# KTBetterZombie
A tool to print out the dealloc backtrace when sending message to Objective-C zombie object. 

## ⚠️ NOT DONE YET

😆

## 🎯 TARGET

In Xcode, sending message to a zombie object will print something to give us a hint:
```
*** -[OTQ description]: message sent to deallocated instance 0x100507150
```
We can know the original class of this zombie, but still don't know the location causing it released.
What I want is recording the backtrace in every -dealloc method, and print it out when sending message to zombie object.
