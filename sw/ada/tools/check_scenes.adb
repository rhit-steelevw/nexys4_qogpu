with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces;
with Qogpu_Fixed;

procedure Check_Scenes is
   use Ada.Text_IO;
   use Qogpu_Fixed;
   use type Interfaces.Unsigned_32;

   subtype Word is Interfaces.Unsigned_32;
   type Memory is array (Natural range 0 .. 1023) of Word;
   Expected : Memory := (others => 0);
   type Vertex_Table is array (Positive range <>, Positive range <>) of Q16;
   Vertices : constant Vertex_Table (1 .. 6, 1 .. 3) :=
     ((-49152,  32768, -32768),
      ( 16384,  32768, -32768),
      (-16384, -49152, -32768),
      (-16384,  49152,  32768),
      ( 49152,  49152,  32768),
      ( 16384, -32768,  32768));
   Input : File_Type;
   Check_Failed : exception;

   procedure Fail (Message : String) is
   begin
      Put_Line ("FAIL: " & Message);
      raise Check_Failed;
   end Fail;

   function Raw_Word (Value : Q16) return Word is
   begin
      -- Convert negative coordinates to their 32-bit two's-complement bits.
      if Value < 0 then
         return Word (Wide (Value) + 2 ** 32);
      else
         return Word (Value);
      end if;
   end Raw_Word;

   function Read_Word (Address : Natural) return Word is
      Result : Word := 0;
   begin
      if End_Of_File (Input) then
         Fail ("file ended before word" & Natural'Image (Address));
      end if;
      declare
         Line : constant String := Get_Line (Input);
      begin
         if Line'Length /= 32 then
            Fail ("word" & Natural'Image (Address) & " must have 32 bits");
         end if;
         for Bit of Line loop
            if Bit /= '0' and Bit /= '1' then
               Fail ("non-binary character at word" & Natural'Image (Address));
            end if;
            Result := Result * 2;
            if Bit = '1' then
               Result := Result + 1;
            end if;
         end loop;
      end;
      return Result;
   end Read_Word;
begin
   if Ada.Command_Line.Argument_Count > 1 then
      Fail ("usage: check_scenes [path-to-memory-file]");
   end if;

   -- Six-word vertex stride: X, Y, Z, Xt, Yt, TextureID.
   for V in 1 .. 6 loop
      for Axis in 1 .. 3 loop
         Expected ((V - 1) * 6 + Axis - 1) := Raw_Word (Vertices (V, Axis));
      end loop;
   end loop;
   -- First two face records use one-based vertex indices.
   for I in 0 .. 5 loop
      Expected (144 + I) := Word (I + 1);
   end loop;

   if Ada.Command_Line.Argument_Count = 1 then
      Open (Input, In_File, Ada.Command_Line.Argument (1));
   else
      Open (Input, In_File, "scenes/scene_two_triangles.mem");
   end if;

   for Address in Expected'Range loop
      if Read_Word (Address) /= Expected (Address) then
         Fail ("unexpected value at word" & Natural'Image (Address));
      end if;
   end loop;
   if not End_Of_File (Input) then
      Fail ("extra lines after word 1023");
   end if;
   Close (Input);

   Put_Line ("PASS: 1024 binary words match the two-triangle fixture");
   Put_Line ("Fixture: 6 vertices, 2 faces; unused words checked as zero");
   Put_Line ("Counts and colors are fixture metadata, not encoded fields");
   Put_Line ("Expected Block C mapping at zero rotation, D=8:");
   for V in 1 .. 6 loop
      Put_Line
        ("Vertex" & Integer'Image (V)
         & ": x=" & Q16'Image (Viewport_X (Vertices (V, 1)) / One)
         & " y=" & Q16'Image (Viewport_Y (Vertices (V, 2)) / One)
         & " depth=" & Natural'Image (Depth_Map (Vertices (V, 3), 8)));
   end loop;
   Put_Line ("Expected colors: face 1 green; face 2 blue (not checked in file)");
   Put_Line ("This checks the fixture, not hardware rendering or color storage");
exception
   when Check_Failed =>
      if Is_Open (Input) then
         Close (Input);
      end if;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   when Name_Error | Use_Error | Device_Error | End_Error | Data_Error =>
      if Is_Open (Input) then
         Close (Input);
      end if;
      Put_Line ("FAIL: cannot open or read the memory file; check its path");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Check_Scenes;