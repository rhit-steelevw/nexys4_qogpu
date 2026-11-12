with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Text_IO;
with Interfaces;
with Qogpu_Fixed;
with Qogpu_Raster;

procedure Render_Two_Triangles is
   use Ada.Command_Line;
   use Ada.Text_IO;
   use Qogpu_Fixed;
   use Qogpu_Raster;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_8;

   subtype Word is Interfaces.Unsigned_32;
   subtype Byte is Interfaces.Unsigned_8;
   type Memory is array (Natural range 0 .. 1023) of Word;
   type Vertex_List is array (Positive range 1 .. 6) of Vertex;
   type Face_List is array (Positive range 1 .. 2) of Triangle;
   type Frame is array (Px_Y, Px_X) of Byte;
   type Depth_Buffer is array (Px_Y, Px_X) of Depth8;

   Words : Memory;
   Vertices : Vertex_List;
   Faces : Face_List;
   Face_Colors : constant array (Positive range 1 .. 2) of Byte :=
     (16#1C#, 16#03#); -- Temporary flat colors: green, blue.
   Image, Reversed_Image : Frame;
   Input, Output : File_Type;
   Hex : constant String := "0123456789ABCDEF";

   function Read_Word return Word is
      Value : Word := 0;
   begin
      if End_Of_File (Input) then
         raise Data_Error with "scene ended before 1024 words";
      end if;
      declare
         Raw : constant String := Get_Line (Input);
         Line : constant String :=
           (if Raw'Length > 0 and then Raw (Raw'Last) = ASCII.CR
            then Raw (Raw'First .. Raw'Last - 1) else Raw);
      begin
         if Line'Length /= 32 then
            raise Data_Error with "each scene line must contain 32 binary digits";
         end if;
         for Bit of Line loop
            if Bit /= '0' and then Bit /= '1' then
               raise Data_Error with "scene contains a non-binary character";
            end if;
            Value := Value * 2;
            if Bit = '1' then
               Value := Value + 1;
            end if;
         end loop;
      end;
      return Value;
   end Read_Word;

   function Coordinate (Bits : Word) return Q16 is
   begin
      if Bits > 16#7FFF_FFFF# then
         return Q16 (Wide (Bits) - 2 ** 32);
      end if;
      return Q16 (Bits);
   end Coordinate;

   procedure Render (Reverse_Order : Boolean; Pixels : out Frame) is
      Depths : Depth_Buffer := (others => (others => 255));
   begin
      Pixels := (others => (others => 0));
      for Draw in 1 .. 2 loop
         declare
            F : constant Positive := (if Reverse_Order then 3 - Draw else Draw);
            S : constant Setup_T := Setup (Faces (F));
         begin
            for Y in S.Ymin .. S.Ymax loop
               for X in S.Xmin .. S.Xmax loop
                  if Covered (S, X, Y) then
                     declare
                        Z : constant Depth8 := Interp_Z (S, X, Y);
                     begin
                        if Depth_Pass (Z, Depths (Y, X)) then
                           Depths (Y, X) := Z;
                           Pixels (Y, X) := Face_Colors (F);
                        end if;
                     end;
                  end if;
               end loop;
            end loop;
         end;
      end loop;
   end Render;

begin
   if Argument_Count /= 2 then
      Put_Line ("Usage: render_two_triangles input.mem output.hex");
      Set_Exit_Status (Failure);
      return;
   end if;
   if Argument (1) = Argument (2) then
      raise Use_Error with "use different input and output paths";
   end if;

   Open (Input, In_File, Argument (1));
   for Address in Words'Range loop
      Words (Address) := Read_Word;
   end loop;
   if not End_Of_File (Input) then
      raise Data_Error with "extra lines after scene word 1023";
   end if;
   Close (Input);

   -- Read this fixture's six vertices and two faces, using the existing layout.
   for V in Vertices'Range loop
      declare
         Base : constant Natural := (V - 1) * 6;
      begin
         Vertices (V) :=
           (X => Viewport_X (Coordinate (Words (Base))),
            Y => Viewport_Y (Coordinate (Words (Base + 1))),
            Z => Depth_Map (Coordinate (Words (Base + 2)), 8));
      end;
   end loop;
   for F in Faces'Range loop
      for Corner in Index loop
         declare
            ID : constant Word := Words (144 + (F - 1) * 3 + Natural (Corner));
         begin
            if ID < 1 or else ID > 6 then
               raise Data_Error with "fixture face indices must be in 1..6";
            end if;
            Faces (F) (Corner) := Vertices (Positive (ID));
         end;
      end loop;
   end loop;

   Render (False, Image); -- Near green first, far blue second.
   Render (True, Reversed_Image);
   if Image /= Reversed_Image then
      raise Program_Error with "image changed when draw order was reversed";
   end if;
   if Image (0, 0) /= 16#00# or else Image (80, 80) /= 16#1C#
     or else Image (60, 240) /= 16#03# or else Image (100, 160) /= 16#1C#
   then
      raise Program_Error with "expected fixture pixel check failed";
   end if;

   Create (Output, Out_File, Argument (2));
   for Y in Px_Y loop
      for X in Px_X loop
         declare
            P : constant Natural := Natural (Image (Y, X));
         begin
            Put_Line (Output, String'(Hex (P / 16 + 1), Hex (P mod 16 + 1)));
         end;
      end loop;
   end loop;
   Close (Output);
   Put_Line ("PASS: sample pixels and reversed draw order");
   Put_Line ("Wrote 76800 RGB332 pixels: " & Argument (2));
   Put_Line ("Synthetic Ada preview only; no FPGA or Block A/B test");
exception
   when E : others =>
      if Is_Open (Input) then
         Close (Input);
      end if;
      if Is_Open (Output) then
         Close (Output);
      end if;
      Put_Line (Standard_Error, "FAIL: " & Ada.Exceptions.Exception_Message (E));
      Set_Exit_Status (Failure);
end Render_Two_Triangles;