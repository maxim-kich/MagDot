#include <stdint.h>
typedef void (*TapSample)(double seconds, double x, double y, double z);
int magdot_sensor_start(TapSample callback);
void magdot_sensor_stop(void);

int magdot_sensor_access(void);
int magdot_sensor_request(void);
int magdot_touch_start(void);
void magdot_touch_stop(void);
double magdot_touch_age(void);
int magdot_touch_available(void);

uint64_t magdot_touch_frames(void);

int magdot_touch_decoder_selftest(void);
