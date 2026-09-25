#ifndef TOUCH_INPUT_H
#define TOUCH_INPUT_H

#include <stdint.h>

void touch_input_begin();
bool touch_input_read(uint16_t *x, uint16_t *y, uint8_t orientation);

#endif
