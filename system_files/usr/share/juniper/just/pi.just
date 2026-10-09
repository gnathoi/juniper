# Show Pi temperature, throttling and clock speed
pi-status:
    sudo vcgencmd measure_temp
    sudo vcgencmd get_throttled
    sudo vcgencmd measure_clock arm
