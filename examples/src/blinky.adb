with Board;
with Gpio;
with Debug;

--  LD0 toggles every half second. The other LEDs mirror the switches, and
--  a pressed button is named on the console.

procedure Blinky is
   Count : Natural := 0;
begin
   Board.Initialize;
   Debug.Put_Line ("blinky on nexys4");

   loop
      Gpio.Toggle (Board.Led);
      Count := Count + 1;
      Debug.Put_Line ("tick" & Debug.Img (Count));

      for S in Board.Switch_Index range 1 .. 15 loop
         if Board.Switch_On (S) then
            Gpio.Set (Board.Leds (Board.Led_Index (S)));
         else
            Gpio.Clr (Board.Leds (Board.Led_Index (S)));
         end if;
      end loop;

      for B in Board.Button loop
         if Board.Button_Pressed (B) then
            Debug.Put_Line ("button " & B'Image);
         end if;
      end loop;

      delay 0.5;
   end loop;
end Blinky;
