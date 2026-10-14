with Gpio_Types;
with Usart_Types;
with Board_GPIO;
with NEORV32_System;
with Debug;
with MT;

with Last_Chance_Handler;
pragma Unreferenced (Last_Chance_Handler);

package body Board is

   use type MT.Bit;

   --  -------------------------------------------------------------------
   --  GPIO initialization
   --  -------------------------------------------------------------------

   procedure Init_Led_Gpio is
      Cfg : constant Gpio_Types.Gpio_Config :=
        (Mode       => Gpio_Types.Output,
         Pull       => Gpio_Types.None,
         Drive      => Gpio_Types.Push_Pull,
         Speed      => Gpio_Types.Low_Speed,
         Init_State => Gpio_Types.Low);
   begin
      for L of Board_GPIO.Leds loop
         Gpio.Configure (L, Cfg);
      end loop;
   end Init_Led_Gpio;

   procedure Init_Input_Gpio is
      Cfg : constant Gpio_Types.Gpio_Config := (Mode => Gpio_Types.Input, Pull => Gpio_Types.None);
   begin
      for S of Board_GPIO.Switches loop
         Gpio.Configure (S, Cfg);
      end loop;
      for B of Board_GPIO.Buttons loop
         Gpio.Configure (B, Cfg);
      end loop;
   end Init_Input_Gpio;

   --  -------------------------------------------------------------------
   --  Version check
   --
   --  The neorv32 crate is written for one NEORV32 release. A bitstream of
   --  another release has different registers, and a driver on it fails in
   --  ways nobody can trace. So this is the first thing checked, and a
   --  mismatch stops here with a message instead of running on.
   --  -------------------------------------------------------------------

   procedure Halt_On_Version_Mismatch is
   begin
      Debug.Put_Line ("NEORV32 version mismatch");
      Debug.Put_Line
        ("  bitstream has   0x"
         & Debug.Hex (Natural (NEORV32_System.Hardware_Version)));
      Debug.Put_Line
        ("  drivers expect  0x"
         & Debug.Hex (Natural (NEORV32_System.Expected_Version)));
      Debug.Put_Line
        ("Load the bitstream of the matching neorv32_nexys4 release.");

      loop
         for L of Board_GPIO.Leds loop
            Gpio.Toggle (L);
         end loop;
         delay 0.1;
      end loop;
   end Halt_On_Version_Mismatch;

   --  -------------------------------------------------------------------
   --  Public entry point
   --  -------------------------------------------------------------------

   procedure Initialize is
   begin
      --  Console first, so the version check has somewhere to report.
      --  The UART pins are fixed in the gateware: no GPIO to configure.
      Console.Open
        ((Baud      => Usart_Types.B19200,
          Data_Bits => Usart_Types.Data_8,
          Parity    => Usart_Types.None,
          Stop_Bits => Usart_Types.Stop_1,
          Flow      => Usart_Types.None));

      Init_Led_Gpio;
      Init_Input_Gpio;

      if not NEORV32_System.Version_Matches then
         Halt_On_Version_Mismatch;
      end if;
   end Initialize;

   function Switch_On (S : Switch_Index) return Boolean is
   begin
      return Gpio.Read (Board_GPIO.Switches (S)) = 1;
   end Switch_On;

   function Button_Pressed (B : Button) return Boolean is
   begin
      return Gpio.Read (Board_GPIO.Buttons (B)) = 1;
   end Button_Pressed;

end Board;
