OBJECTS = cbuffer.o ctcp.o async.o
CXXFLAGS = -fPIC
LDFLAGS = -shared -luv -lstdc++

all: libasync.so
clean:
	rm -f *.o ; rm -f  *.so

libasync.so: $(OBJECTS) 
	c++ ${LDFLAGS} ${OBJECTS} -o $@

%.o: %.cpp
	c++ ${CXXFLAGS} -c -o $@ $<

