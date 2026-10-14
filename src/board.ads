with Instances;
with Board_GPIO;

with Gpio;

package Board is

   --  -------------------------------------------------------------------
   --  Buses (vendor-neutral facades over MCU-level instances)
   --
   --  Naming reflects the SoC wiring in the neorv32_nexys4 bitstream,
   --  not the application role.
   --  -------------------------------------------------------------------

   --  Console: UART0, the USB-UART bridge, 19200 8N1, the same settings as
   --  the bootloader, so one terminal session covers both.
   package Console renames Instances.Console;

   --  -------------------------------------------------------------------
   --  GPIO (board-specific assignments)
   --  -------------------------------------------------------------------

   subtype Led_Index    is Board_GPIO.Led_Index;
   subtype Switch_Index is Board_GPIO.Switch_Index;
   subtype Button       is Board_GPIO.Button;

   Leds     : Board_GPIO.Led_Array    renames Board_GPIO.Leds;
   Switches : Board_GPIO.Switch_Array renames Board_GPIO.Switches;
   Buttons  : Board_GPIO.Button_Array renames Board_GPIO.Buttons;

   --  The LED, when an application needs only one: LD0.
   Led : Gpio.Pin renames Board_GPIO.Leds (0);

   procedure Initialize;
   --  Opens the console, checks that the bitstream carries the NEORV32
   --  release the drivers were written for, and sets up the LEDs, switches
   --  and buttons. On a version mismatch it prints both versions on the
   --  console and stops there, blinking all LEDs. It does not return.

   function Switch_On (S : Switch_Index) return Boolean;
   function Button_Pressed (B : Button) return Boolean;

end Board;
