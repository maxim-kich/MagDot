#include <stdint.h>
typedef void (*TapSample)(double seconds, double x, double y, double z);
int sensor_start(TapSample callback);
void sensor_stop(void);
