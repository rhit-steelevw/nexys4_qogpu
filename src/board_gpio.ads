--  Board_GPIO: complete GPIO pin map for the Nexys 4 and Nexys 4 DDR with the
--  neorv32_nexys4 bitstream. Every pin used on this board is declared here.
--
--  On NEORV32 the GPIO numbers are not FPGA pins: the gateware decides which
--  FPGA pin each GPIO line drives, and it differs between the Nexys 4 and the
--  Nexys 4 DDR. The numbers below are the same on both; only the constraints
--  of neorv32_nexys4 differ.
--
--  NEORV32 outputs and inputs are separate lines: output N and input N are
--  two different wires. LEDs are outputs 0 .. 15, switches inputs 0 .. 15,
--  buttons inputs 16 .. 20.
--
--  UART0 has no GPIO: its two wires go straight from the SoC to the USB-UART
--  bridge in the gateware. There is nothing to configure on the software side.

with Gpio;
with NEORV32_GPIO;

package Board_GPIO is

   --  LD0 .. LD15, active-high. LD0 is also the bootloader status LED.
   type Led_Index is range 0 .. 15;
   type Led_Array is array (Led_Index) of Gpio.Pin;

   Leds : constant Led_Array :=
     (NEORV32_GPIO.Make_Pin (0),  NEORV32_GPIO.Make_Pin (1),
      NEORV32_GPIO.Make_Pin (2),  NEORV32_GPIO.Make_Pin (3),
      NEORV32_GPIO.Make_Pin (4),  NEORV32_GPIO.Make_Pin (5),
      NEORV32_GPIO.Make_Pin (6),  NEORV32_GPIO.Make_Pin (7),
      NEORV32_GPIO.Make_Pin (8),  NEORV32_GPIO.Make_Pin (9),
      NEORV32_GPIO.Make_Pin (10), NEORV32_GPIO.Make_Pin (11),
      NEORV32_GPIO.Make_Pin (12), NEORV32_GPIO.Make_Pin (13),
      NEORV32_GPIO.Make_Pin (14), NEORV32_GPIO.Make_Pin (15));

   --  SW0 .. SW15, read 1 when up.
   type Switch_Index is range 0 .. 15;
   type Switch_Array is array (Switch_Index) of Gpio.Pin;

   Switches : constant Switch_Array :=
     (NEORV32_GPIO.Make_Pin (0),  NEORV32_GPIO.Make_Pin (1),
      NEORV32_GPIO.Make_Pin (2),  NEORV32_GPIO.Make_Pin (3),
      NEORV32_GPIO.Make_Pin (4),  NEORV32_GPIO.Make_Pin (5),
      NEORV32_GPIO.Make_Pin (6),  NEORV32_GPIO.Make_Pin (7),
      NEORV32_GPIO.Make_Pin (8),  NEORV32_GPIO.Make_Pin (9),
      NEORV32_GPIO.Make_Pin (10), NEORV32_GPIO.Make_Pin (11),
      NEORV32_GPIO.Make_Pin (12), NEORV32_GPIO.Make_Pin (13),
      NEORV32_GPIO.Make_Pin (14), NEORV32_GPIO.Make_Pin (15));

   --  The five push buttons, read 1 while pressed.
   type Button is (Center, Up, Left, Right, Down);
   type Button_Array is array (Button) of Gpio.Pin;

   Buttons : constant Button_Array :=
     (Center => NEORV32_GPIO.Make_Pin (16),
      Up     => NEORV32_GPIO.Make_Pin (17),
      Left   => NEORV32_GPIO.Make_Pin (18),
      Right  => NEORV32_GPIO.Make_Pin (19),
      Down   => NEORV32_GPIO.Make_Pin (20));

end Board_GPIO;
