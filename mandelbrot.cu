#include <stdio.h>
#include <unistd.h>
#include <err.h>
#include <stdint.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <omp.h>

#include <stdlib.h>
#include <X11/keysym.h>
#include <fcntl.h>

#define CPU_CORES 8
#define BENCHMARK_ITERATIONS 50
int Version = 0;

static int dim = 800;
static int n = 512;
static int m = 512;
static int max_iter = 100;
static uint32_t *colors;
uint32_t *device_colors;

double total_time;
int instances;

#ifdef BENCHMARK
double single_core;
#endif
// X11 data 
#ifdef SHOW_X
static Display *dpy;
static XImage *bitmap;
static Window win;
static Atom wmDeleteMessage;
static GC gc;

//destroy window and x variables 
static void exit_x11(void){
#ifdef BENCHMARK
    printf("\nThe Average time for this version was %f over %d instances.\n", total_time/instances, instances);
#endif
	XDestroyWindow(dpy, win);
	XCloseDisplay(dpy);
}


// create Xwindow 
static void init_x11(){
	// Attempt to open the display 
	dpy = XOpenDisplay(NULL);
	
	// Failure
	if (!dpy) exit(0);
	
	uint32_t long white = WhitePixel(dpy,DefaultScreen(dpy));
	uint32_t long black = BlackPixel(dpy,DefaultScreen(dpy));
	

	win = XCreateSimpleWindow(dpy, DefaultRootWindow(dpy),
            0, 0, dim, dim, 0, black, white);
	
	// We want to be notified when the window appears 
	XSelectInput(dpy, win, StructureNotifyMask);
	
	// Make it appear 
	XMapWindow(dpy, win);
	
	while (1){
        XEvent e;
		XNextEvent(dpy, &e);
		if (e.type == MapNotify) break;
	}
	
	XTextProperty tp;
    char name1[128] = "Mandelbrot Single Core";
    char* n = name1;
	Status st = XStringListToTextProperty(&n, 1, &tp);
	if (st) XSetWMName(dpy, win, &tp);

	// Wait for the MapNotify event 
	XFlush(dpy);
    int depth = DefaultDepth(dpy, DefaultScreen(dpy));    
    Visual *visual = DefaultVisual(dpy, DefaultScreen(dpy));

    bitmap = XCreateImage(dpy, visual, depth, ZPixmap, 0,
            (char*) malloc(dim * dim * 32), dim, dim, 32, 0);

	// Init GC 
	gc = XCreateGC(dpy, win, 0, NULL);
	XSetForeground(dpy, gc, black);
	
	XSelectInput(dpy, win, ExposureMask | ButtonPressMask | Button3MotionMask | KeyPressMask | StructureNotifyMask);
	
	wmDeleteMessage = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
	XSetWMProtocols(dpy, win, &wmDeleteMessage, 1);
}
#endif

//create colors used to draw the mandelbrot set 
void init_colours(void) {
    float freq = 6.3 / max_iter;
	for (int i = 0; i < max_iter; i++){
        char r = sin(freq * i + 3) * 127 + 128;
        char g = sin(freq * i + 5) * 127 + 128;
        char b = sin(freq * i + 1) * 127 + 128;
		
		colors[i] = b + 256 * g + 256 * 256 * r;
	}
	
	colors[max_iter] = 0;
}

void checkErr(cudaError_t err, char* msg){
    if (err != cudaSuccess){
        fprintf(stderr, "%s (error code %d: '%s'", msg, err, cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
}



// Here we have the single core version for mandel_double
uint32_t mandel_double_single(double cr, double ci, int max_iter) {
    double zr = 0, zi = 0, zrsqr = 0, zisqr = 0;

    uint32_t i;

    for (i = 0; i < max_iter; i++){
		zi = zr * zi;
		zi += zi;
		zi += ci;
		zr = zrsqr - zisqr + cr;
		zrsqr = zr * zr;
		zisqr = zi * zi;
		
    //the fewer iterations it takes to diverge, the farther from the set
		if (zrsqr + zisqr > 4.0) break;
    }
    return i;
}

void mandel_single(uint32_t *counts, double xmin, double ymin,
            double step, int max_iter, int dim, uint32_t *colors) {
    int i, x, y;
    double cr, ci;
    if (Version == 1){
        # pragma omp parallel for num_threads(CPU_CORES) \
            schedule(runtime) private(i,x,y,cr,ci) \
            shared(counts, dim, colors, xmin, ymin, step, max_iter)
        for (i = 1; i < dim*dim; i++){
            x = i % dim;
            y = i / dim;
            cr = xmin + x * step;
            ci = ymin + y * step;
            counts[y * dim + x]  = colors[mandel_double_single(cr, ci, max_iter)];
        }
    } else {
        for (i = 1; i < dim*dim; i++){
            x = i % dim;
            y = i / dim;
            cr = xmin + x * step;
            ci = ymin + y * step;
            counts[y * dim + x]  = colors[mandel_double_single(cr, ci, max_iter)];
        }
    }
}

double display_double_single(double xcen, double ycen, double scale,
        uint32_t *host_counts, uint32_t *colors){
    dim3 numBlocks(dim,dim);
    double xmin = xcen - (scale/2);
    double ymin = ycen - (scale/2);
    double step = scale / dim;

#ifdef BENCHMARK
    double start = omp_get_wtime();
#endif 
    mandel_single(host_counts, xmin, ymin, step, max_iter, dim, colors);

#ifdef SHOW_X
    memcpy(bitmap->data, host_counts, dim * dim * sizeof(uint32_t));
#else
    void *data = malloc(dim * dim * sizeof(uint32_t));
    memcpy(data, host_counts, dim * dim * sizeof(uint32_t));
#endif

#ifdef BENCHMARK
    double stop = omp_get_wtime();
    //if (Version == 0) printf("Version: Single Core\tTime: %f\r", stop - start);
    //else printf("Version: OpenMP\t\tTime: %f\r", stop - start);
    fflush(stdout);
#endif

#ifdef SHOW_X
    XPutImage(dpy, win, gc, bitmap,
        0, 0, 0, 0,
        dim, dim);
    XFlush(dpy); 
#endif
#ifdef BENCHMARK
    return stop-start;
#endif
    return 0;
}




/* the mandelbrot set is defined as all complex numbers c such that the 
   equation z = z^2 + c remains bounded. In practice, we calculate max_iter
   iterations of this formula and if the magnitude of z is < 2 we assume it
   is in the set. The greater max_iters the more accurate our representation */
__device__ uint32_t mandel_double(double cr, double ci, int max_iter) {
    double zr = 0;
    double zi = 0;
    double zrsqr = 0;
    double zisqr = 0;

    uint32_t i;

    for (i = 0; i < max_iter; i++){
		zi = zr * zi;
		zi += zi + ci;
		zr = zrsqr - zisqr + cr;
		zrsqr = zr * zr;
		zisqr = zi * zi;
		
    //the fewer iterations it takes to diverge, the farther from the set
		if (zrsqr + zisqr > 4.0) break;
    }
	
    return i;
}

/* turn each x y coordinate into a complex number and run the mandelbrot formula on it */
__global__ void mandel_kernel(uint32_t *counts, double xmin, double ymin,
            double step, int max_iter, int dim, uint32_t *colors) {
    int pix_per_thread = dim * dim / (gridDim.x * blockDim.x);
    int tId = blockDim.x * blockIdx.x + threadIdx.x;
    int offset = pix_per_thread * tId;
    for (int i = offset; i < offset + pix_per_thread; i++){
        int x = i % dim;
        int y = i / dim;
        double cr = xmin + x * step;
        double ci = ymin + y * step;
        counts[y * dim + x]  = colors[mandel_double(cr, ci, max_iter)];
    }
    if (gridDim.x * blockDim.x * pix_per_thread < dim * dim
            && tId < (dim * dim) - (blockDim.x * gridDim.x)){
        int i = blockDim.x * gridDim.x * pix_per_thread + tId;
        int x = i % dim;
        int y = i / dim;
        double cr = xmin + x * step;
        double ci = ymin + y * step;
        counts[y * dim + x]  = colors[mandel_double(cr, ci, max_iter)];
    }
}

/* For each point, evaluate its colour */
double display_double_cuda(double xcen, double ycen, double scale,
        uint32_t *dev_counts, uint32_t *colors){
    dim3 numBlocks(dim,dim);
    
    double xmin = xcen - (scale/2);
    double ymin = ycen - (scale/2);
    double step = scale / dim;
    cudaError_t err = cudaSuccess;

#ifdef BENCHMARK
    double start = omp_get_wtime();
#endif 

    mandel_kernel<<<n, m>>>(dev_counts, xmin , ymin, step, max_iter, dim, colors);
    checkErr(err, (char*)"Failed to run Kernel");
#ifdef SHOW_X
    err = cudaMemcpy(bitmap->data, dev_counts, dim * dim * sizeof(uint32_t), cudaMemcpyDeviceToHost);
#else
    void *data = malloc(dim * dim * sizeof(uint32_t));
    err = cudaMemcpy(data, dev_counts, dim * dim * sizeof(uint32_t), cudaMemcpyDeviceToHost);
#endif
    checkErr(err, (char*)"Failed to copy dev_counts back");

#ifdef BENCHMARK
    double stop = omp_get_wtime();
    //printf("Version: CUDA\t\tTime: %f\r", stop - start);
    fflush(stdout);
#endif
#ifdef SHOW_X
    XPutImage(dpy, win, gc, bitmap,
        0, 0, 0, 0,
        dim, dim);
    XFlush(dpy); 
#endif
#ifdef BENCHMARK
    return stop-start;
#endif
    return 0;
}

void display_double(double xcen, double ycen, double scale,
        uint32_t *dev_counts, uint32_t *colors){ 
    if (Version == 2) total_time += display_double_cuda(xcen, ycen, scale, dev_counts, colors);
    else total_time += display_double_single(xcen, ycen, scale, dev_counts, colors);
    instances++;
}

void swapVersion(void) {
    fflush(stdout);
#ifdef BENCHMARK
    double speedup;
    if (Version == 0) {
        single_core = total_time/instances; 
        printf("Avg time for Single: %.6f   Instances: %d\tSpeedup: 1\n", total_time/instances, instances);
    } else {
        speedup = single_core/(total_time/instances);
        if (Version == 1) printf("Avg time for OpenMP: %.6f   Instances: %d\tSpeedup: %.2f\n", total_time/instances, instances, speedup);
        else printf("Avg time for CUDA:   %.6f   Instances: %d\tSpeedup: %.2f\n", total_time/instances, instances, speedup);
    } 
#endif

    if (++Version > 2) Version = 0;

#ifdef SHOW_X
    XTextProperty tp;
    char name1[128] = "Mandelbrot Single Core";
    char name2[128] = "Mandelbrot OpenMP";
	char name3[128] = "Mandelbrot CUDA";
	char *n;
    if (Version == 0) n = name1;
    else if (Version == 1) n = name2;
    else n = name3;
	Status st = XStringListToTextProperty(&n, 1, &tp);
	if (st) XSetWMName(dpy, win, &tp);
#endif
}

void usage(){

    printf("Usage: benchmark [n] [m] [dim] [max_iter]\n");

    printf("\tn\t\t=\tnumber of blocks (defaults to 512)\n");

    printf("\tm\t\t=\tthreads per block (defaults to 512)\n");

    printf("\tdim\t\t=\twidth/height of canvas in pixels (defaults to 800)\n");

    printf("\tmax_iter\t=\tmax iterations (defaults to 100)\n\n");

    exit(1);
}

int main(int argc, char** argv){
    if(argc < 2){
        usage();
        return 0;
    }

    cudaError_t err = cudaSuccess;
    printf("%s", argv[0]);
    if (argc >= 2){
        n = atoi(argv[1]);
        printf(" %s", argv[1]);
    }
    if (argc >= 3){ 
        m = atoi(argv[2]);
        printf(" %s", argv[2]);
    }
    if (argc >= 4){
        dim = atoi(argv[3]);
        printf(" %s", argv[3]);
    }
    if (argc >= 5){
        max_iter = atoi(argv[4]);
        printf(" %s", argv[4]);
    }
    // if (argc >= 6){
    //     mem_mode = atoi(argv[5]);
    //     printf(" %s", argv[5]);
    // }
    size_t color_size = (max_iter +1) * sizeof(uint32_t);
    colors = (uint32_t *) malloc(color_size);
    cudaMalloc((void**)&device_colors, color_size);
    double xcen = -0.5;
    double ycen = 0;
    double scale = 3;
    printf("\n");
    

#ifdef SHOW_X
	init_x11();
#endif
reset:
#ifdef BENCHMARK
    total_time = 0;
    instances = 0;
#endif
	init_colours();
    cudaMemcpy(device_colors, colors, color_size, cudaMemcpyHostToDevice);

    uint32_t *device_counts = NULL;
    size_t img_size = dim * dim * sizeof(uint32_t);
    err = cudaMalloc(&device_counts, img_size);
    checkErr(err, (char*)"Failed to allocate dev_counts");
    uint32_t* host_counts = (uint32_t*)malloc(img_size);
    if (host_counts == 0) printf("Failed to allocate host_counts\n");

    uint32_t *dev_colors, *dev_counts;
    if (Version == 2) {
        dev_counts = device_counts;
        dev_colors = device_colors;
    } else {
        dev_counts = host_counts;
        dev_colors = colors;
    }
#ifdef BENCHMARK
#ifndef SHOW_X
    for (int i = 0; i < BENCHMARK_ITERATIONS; i++)
        display_double(xcen, ycen, scale, dev_counts, dev_colors);
    if (Version < 2) {
        swapVersion();
        goto reset;
    }
    swapVersion();
    return 0;
#endif
#endif

	display_double(xcen, ycen, scale, dev_counts, dev_colors);

#ifdef SHOW_X
    int getXMotion = 0;
    int getYMotion = 0;
	while(1) {
		XEvent event;
		KeySym key;
		char text[255];
		
		XNextEvent(dpy, &event);
        while (XPending(dpy) > 0)
            XNextEvent(dpy, &event);
		/* Just redraw everything on expose */
		if ((event.type == Expose) && !event.xexpose.count){
			XPutImage(dpy, win, gc, bitmap,
				0, 0, 0, 0,
				dim, dim);
		}

        // scroll to zoom
        if (event.type==ButtonPress) {
            if (event.xbutton.button == 4) {
                scale *= 0.8;
                display_double(xcen, ycen, scale, dev_counts, dev_colors);
            } else if (event.xbutton.button == 5) {
                scale *= 1.20;
                display_double(xcen, ycen, scale, dev_counts, dev_colors);
            }
        }

        // lock positions on drag
        if (event.type==ButtonPress) {
            if (event.xbutton.button == 3) {
                getXMotion = event.xbutton.x;
                getYMotion = event.xbutton.y;
            }
        }

        else if (event.type == MotionNotify) {
            xcen += (getXMotion-event.xbutton.x) * scale / dim;
            ycen += (getYMotion-event.xbutton.y) * scale / dim;
            display_double(xcen, ycen, scale, dev_counts, dev_colors);
            getXMotion = event.xbutton.x;
            getYMotion = event.xbutton.y;
        }
		
		/* Press 'x' to exit */
		if ((event.type == KeyPress) &&
			XLookupString(&event.xkey, text, 255, &key, 0) == 1)
			if (text[0] == 'x') break;

        /* Press 'k' to switch */
		if ((event.type == KeyPress) &&
			XLookupString(&event.xkey, text, 255, &key, 0) == 1)
			if (text[0] == 'k') {
                swapVersion();
                //exit_x11();
                goto reset;
            }

        /* Press 'r' to refresh */
		if ((event.type == KeyPress) &&
			XLookupString(&event.xkey, text, 255, &key, 0) == 1)
			if (text[0] == 'r') display_double(xcen, ycen, scale, dev_counts, dev_colors);

		/* Press 'a' to go left */
		if ((event.type == KeyPress) &&
			XLookupString(&event.xkey, text, 255, &key, 0) == 1)
			if (text[0] == 'a'){
                xcen -= 20 * scale / dim;
                display_double(xcen, ycen, scale, dev_counts, dev_colors);
            }

		/* Press 'w' to go up */
		if ((event.type == KeyPress) &&
			XLookupString(&event.xkey, text, 255, &key, 0) == 1)
			if (text[0] == 'w'){
                ycen -= 20 * scale / dim;
                display_double(xcen, ycen, scale, dev_counts, dev_colors);
            }

		/* Press 's' to go down */
		if ((event.type == KeyPress) &&
			XLookupString(&event.xkey, text, 255, &key, 0) == 1)
			if (text[0] == 's'){
                ycen += 20 * scale / dim;
                display_double(xcen, ycen, scale, dev_counts, dev_colors);
            }

		/* Press 'd' to go right */
		if ((event.type == KeyPress) &&
			XLookupString(&event.xkey, text, 255, &key, 0) == 1)
			if (text[0] == 'd'){
                xcen += 20 * scale / dim;
                display_double(xcen, ycen, scale, dev_counts, dev_colors);
            }

		/* Press 'q' to zoom out */
		if ((event.type == KeyPress) &&
			XLookupString(&event.xkey, text, 255, &key, 0) == 1)
			if (text[0] == 'q'){
                scale *= 1.25;
                display_double(xcen, ycen, scale, dev_counts, dev_colors);
            }

		/* Press 'e' to zoom in */
		if ((event.type == KeyPress) &&
			XLookupString(&event.xkey, text, 255, &key, 0) == 1)
			if (text[0] == 'e'){
                scale *= .80;
                display_double(xcen, ycen, scale, dev_counts, dev_colors);
            }

		/* Or simply close the window */
		if ((event.type == ClientMessage) &&
			((Atom) event.xclient.data.l[0] == wmDeleteMessage))
			break;
	}

    exit_x11();
#endif


    cudaFree(dev_counts);
    cudaFree(dev_colors);
    free(colors);
    free(host_counts);

	return 0;
}
