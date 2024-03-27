OBJECTS = cbuffer.o

all: libasync.so
clean:
	rm -f *.o ; rm -f  *.so

libasync.so: $(OBJECTS) 
	ld -shared -luv -o $@ $(OBJECTS)

%.o: %.cpp
	c++ -c -fPIC -o $@ $<

