-- cpu.vhd: Simple 8-bit CPU (BrainF*ck interpreter)
-- Copyright (C) 2019 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): Adam Žitňanský xzitna02
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
entity cpu is
 port (
   CLK   : in std_logic;  -- hodinovy signal
   RESET : in std_logic;  -- asynchronni reset procesoru
   EN    : in std_logic;  -- povoleni cinnosti procesoru
 
   -- synchronni pamet RAM
   DATA_ADDR  : out std_logic_vector(12 downto 0); -- adresa do pameti
   DATA_WDATA : out std_logic_vector(7 downto 0); -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
   DATA_RDATA : in std_logic_vector(7 downto 0);  -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
   DATA_RDWR  : out std_logic;                    -- cteni (0) / zapis (1)
   DATA_EN    : out std_logic;                    -- povoleni cinnosti
   
   -- vstupni port
   IN_DATA   : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
   IN_VLD    : in std_logic;                      -- data platna
   IN_REQ    : out std_logic;                     -- pozadavek na vstup data
   
   -- vystupni port
   OUT_DATA : out  std_logic_vector(7 downto 0);  -- zapisovana data
   OUT_BUSY : in std_logic;                       -- LCD je zaneprazdnen (1), nelze zapisovat
   OUT_WE   : out std_logic                       -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'
 );
end cpu;

-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is

  --program counter
  signal pc_val : std_logic_vector(12 downto 0);
  signal inc_pc : std_logic;
  signal dec_pc : std_logic;

 -- cnt -citac pre zanorenia cyklu while
 signal cnt_val : std_logic_vector (12 downto 0); 
 signal inc_cnt : std_logic;
 signal dec_cnt : std_logic;

 --ptr
 signal ptr_val : std_logic_vector(12 downto 0);
 signal inc_ptr : std_logic;
 signal dec_ptr : std_logic; 

 --multiplexory- select signaly
 signal mx1_sel : std_logic;
 signal mx2_sel : std_logic;
 signal mx2_out : std_logic_vector(12 downto 0); --vystup mux2
 signal mx3_sel : std_logic_vector(1 downto 0);

 --fsm declaration
 type FSMstate is (
                  SFetch,  --nacitavanie instrukcie
                  SDecode, --dekodovanie instrukcie              
                  SIdle,   --idle
                  SPtrInc, --inkrementacia pointra do pamati
                  SPtrDec, --dekrementacia pointra do pamati
                  SCellInc1, SCellInc2, --inkrementacia hodnoty bunky
                  SCellDec1, SCellDec2, --dekrementacia hodnoty bunky
                  SWhileStart1, SWhileStart2, SWhileStart3, SWhileStart4, SWhileStart5, --zaciatok cyklu while
                  SWhileEnd1, SWhileEnd2, SWhileEnd3, SWhileEnd4, SWhileEnd5, --koniec cyklu while
                  SPut1, SPut2, --putchar
                  SGet1, SGet2, --getchar
                  STmpRead1, STmpRead2, --ulozenie obsahu RAM[ptr] do tmp
                  STmpWrite1, STmpWrite2, --zapis obsahu tmp do RAM[ptr]
                  SOther, --neznama instrukcia
                  SHalt  --koniec
                  );

  signal pstate : FSMstate; -- actual state
  signal nstate : FSMstate; -- next state

begin

  --program counter register
  program_counter_reg: process (CLK, RESET, inc_pc, dec_pc)
	begin
		if RESET = '1' then
			pc_val <= (others => '0');
		elsif CLK'event and CLK = '1' then
			if inc_pc = '1' then
				pc_val <= pc_val + 1;
			elsif dec_pc = '1' then
				pc_val <= pc_val - 1;
			end if;
		end if;
	end process;

  --cnt register 
  cnt_reg: process (CLK, RESET, inc_cnt, dec_cnt)
begin
  if RESET = '1' then
    cnt_val <= (others => '0');
  elsif CLK'event and CLK = '1' then
    if inc_cnt = '1' then
      cnt_val <= cnt_val + 1;
    elsif dec_cnt = '1' then
      cnt_val <= cnt_val - 1;
    end if;
  end if;
end process;

  -- register ptr 
  ptr_reg: process (CLK, RESET, inc_cnt, dec_cnt)
begin
  if RESET = '1' then
    ptr_val <= "1000000000000";
  elsif CLK'event and CLK = '1' then
    if inc_ptr = '1' then
      ptr_val <= ptr_val + 1;
    elsif dec_ptr = '1' then
      ptr_val <= ptr_val - 1;
    end if;
  end if;
end process;


--multiplexor1 vyber medzi adresou do dat a adresou kodu
process(pc_val, mx2_out ,mx1_sel)
begin
   case mx1_sel is
      when '0' => DATA_ADDR <= pc_val;
      when '1' => DATA_ADDR <= mx2_out;
      when others => DATA_ADDR <= mx2_out; -- toto nenastane
   end case;
end process;


--multiplexor2
process(ptr_val ,mx2_sel)
begin
   case mx2_sel is
      when '0' => mx2_out <= ptr_val;
      when '1' => mx2_out <= "1000000000000";
      when others => mx2_out <= "1000000000000"; -- toto nenastane
   end case;
end process;

--multiplexor3 vyber zapisovanej hodnoty
process(DATA_RDATA, IN_DATA ,mx3_sel)
begin
   case mx3_sel is
      when "00" => DATA_WDATA <= IN_DATA;
      when "01" => DATA_WDATA <= DATA_RDATA - 1;
      when "10" => DATA_WDATA <= DATA_RDATA + 1;
      when others => DATA_WDATA <= DATA_RDATA;
   end case;
end process;


---------------------------------------------------------
--FSM
---------------------------------------------------------
pstatereg: process(RESET, CLK)
begin
   if (RESET ='1') then
      pstate <= SIdle;
   elsif (CLK'event) and (CLK='1') then
      pstate <= nstate;
   end if;
end process;
 
--Next State logic, Output logic
nstate_logic: process(pstate, OUT_BUSY, IN_VLD, EN, IN_DATA, DATA_RDATA)
begin
   -- default values
   inc_cnt <= '0';
   dec_cnt <= '0';
   inc_ptr <= '0';
   dec_ptr <= '0';
   inc_pc <= '0';
   dec_pc <= '0';
   mx1_sel <= '0';
   mx2_sel <= '0';
   mx3_sel <= "00";

   DATA_EN <= '0';
   DATA_RDWR <= '0';
   OUT_WE <= '0';
	IN_REQ <= '0';
 
  case pstate is
      when SIdle =>
			 if EN = '1' then
				nstate <= SFetch;
			 else
				nstate <= SIdle;
			 end if;
 
      when SFetch =>
           nstate <= SDecode;
           mx1_sel <= '0'; --DATA_ADRESS  <= PC
           DATA_RDWR <= '0';
           DATA_EN <= '1'; --DATA_RDATA <= RAM[PC]

      when SDecode =>
           case DATA_RDATA is
              when X"3E" =>
                  nstate <= SPtrInc;
              when X"3C" =>
                  nstate <= SPtrDec;              
              when X"2B" =>
                  nstate <= SCellInc1;
              when X"2D" =>
                  nstate <= SCellDec1;
              when X"5B" =>
                  nstate <= SWhileStart1;
              when X"5D" =>
                  nstate <= SWhileEnd1;
              when X"2E" =>
                  nstate <= SPut1;
              when X"2C" =>
                  nstate <= SGet1;
              when X"24" =>
                  nstate <= STmpRead1;
              when X"21" =>
                  nstate <= STmpWrite1;
              when X"00" =>
                  nstate <= SHalt;        
              when others => nstate <= SOther;
			 end case;
      
      when SPtrInc =>
          inc_ptr <= '1';
          inc_pc <= '1';
          nstate <= SFetch;

      when SPtrDec =>
          dec_ptr <= '1';
          inc_pc <= '1';
          nstate <= SFetch;

      when SCellInc1 =>
			 mx1_sel <= '1';
          mx2_sel <= '0';
          DATA_RDWR <= '0';
          DATA_EN <= '1'; --DATA_RDATA = RAM[PTR]
          nstate <= SCellInc2;
      
      when SCellInc2 =>
				mx1_sel <= '1';
            mx2_sel <= '0';
            mx3_sel <= "10";
            DATA_RDWR <= '1';
            DATA_EN <= '1';
            inc_pc <= '1'; 
            nstate <= SFetch;
        
      when SCellDec1 =>
			 mx1_sel <= '1';
          mx2_sel <= '0';
          DATA_RDWR <= '0';
          DATA_EN <= '1'; --DATA_RDATA = RAM[PTR]
          nstate <= SCellDec2;
      
      when SCellDec2 =>
            mx2_sel <= '0';
            mx1_sel <= '1';
            mx3_sel <= "01";
            DATA_RDWR <= '1';
            DATA_EN <= '1';
            inc_pc <= '1';
            nstate <= SFetch;
      
      when SPut1 =>
            mx2_sel <=  '0';
            mx1_sel <= '1';
            DATA_RDWR <= '0';
            DATA_EN <= '1';
            nstate <= SPut2;
      
      when SPut2 =>
            if OUT_BUSY <= '0' then
                OUT_WE <= '1';
                OUT_DATA <= DATA_RDATA;
                inc_pc <= '1';
                nstate <= SFetch;
            else
              nstate <= SPut2;  --cakanie kym nebude out_busy = 1
            end if;
      
      when SGet1 =>
              nstate <= SGet2;
              IN_REQ <= '1';    --poziadavka na vstup

      when SGet2 =>
              if IN_VLD = '1' then                  
                  mx1_sel <= '1';   --nastavenie adresy na zapis
                  mx2_sel <= '0';                  
                  mx3_sel <= "00";  --vyber zapisovanych dat                  
                  DATA_RDWR <= '1'; --povolenie zapisu
                  DATA_EN <= '1';    
                  inc_pc <= '1';    --moze sa pokracovat na dalsiu instrukciu
                  nstate <= SFetch;
              else
                nstate <= SGet2; --cakanie kym IN_VLD = 1
              end if ;
      
      when STmpRead1 =>              
              mx1_sel <= '1'; --vyber adresy z ktm sa ma citat
              mx2_sel <= '0';
              DATA_RDWR <= '0'; --povolenie citania
              DATA_EN <= '1'; 
              nstate <= STmpRead2;
      
      when STmpRead2 =>              
              mx1_sel <= '1'; --vyber adresy na zapis
              mx2_sel <= '1';
              mx3_sel <= "11";  --vyber zapisovanych dat   
              DATA_RDWR <= '1'; --povolenie zapisu
              DATA_EN <= '1'; 
              nstate <= SFetch; --pokracovanie na dalsiu instrukciu
              inc_pc <= '1'; 

      when STmpWrite1 =>              
              mx1_sel <= '1'; --nastavenia adresy z kt sa ma citat na adresu tmp
              mx2_sel <= '1';
              DATA_RDWR <= '0'; --povolenie citania
              DATA_EN <= '1'; 
              nstate <= STmpWrite2;
      
      when STmpWrite2 =>              
              mx1_sel <= '1'; --nastavenie adresy na zapis na ptr
              mx2_sel <= '0';
              mx3_sel <= "11"; --vyber zapisovanych dat 
              DATA_RDWR <= '1'; --povolenie zapisu
              DATA_EN <= '1';   
              nstate <= SFetch; --pokracovanie na dalsiu instrukciu
              inc_pc <= '1';
      
      when SWhileStart1 =>
              mx1_sel <= '1';
              mx2_sel <= '0';
              DATA_RDWR <= '0';
              DATA_EN <=  '1';
              nstate <= SWhileStart2;
      
      when SWhileStart2 =>
           --otestujeme podmienku whilu
           if DATA_RDATA = X"00" then
              inc_cnt <= '1';
              nstate <= SWhileStart3;
           else
              nstate <= SFetch;
           end if;
           inc_pc <= '1';
      
     when SWhileStart3 =>
            mx1_sel <= '0'; --nacitanie dalsej instrukcie
            DATA_RDWR <= '0';
            DATA_EN <= '1';
				nstate <= SWhileStart4;

     when SWhileStart4 =>
            --pocitanie zanorenia
            if DATA_RDATA = X"5B" then -- [ instruct
                inc_cnt <= '1';
            elsif DATA_RDATA = X"5D" then
                dec_cnt <= '1';
            end if;
				nstate <= SWhileStart5;

      when SWhileStart5 =>
            if cnt_val = "0000000000000" then
                nstate <= SFetch;
            else
                nstate <= SWhileStart3;
				end if;
				inc_pc <= '1';

      when SWhileEnd1 =>
                mx1_sel <= '1';
                mx2_sel <= '0';
                DATA_RDWR <= '0';
                DATA_EN <=  '1';
                nstate <= SWhileEnd2;
      
      when SWhileEnd2 =>
          --otestujeme podmienku whilu
          if DATA_RDATA = X"00" then
              inc_pc <= '1';
              nstate <= SFetch;
          else
              inc_cnt <= '1';
              dec_pc  <= '1';
              nstate <= SWhileEnd3;
          end if;
      
      when SWhileEnd3 =>
          --nacitanie dalsej instrukcie
          mx1_sel <= '0';
          DATA_RDWR <= '0';
          DATA_EN <= '1';
          nstate <=SWhileEnd4;

      when SWhileEnd4 =>
          --pocitanie zanorenia
          if DATA_RDATA = X"5B" then -- [ 
              dec_cnt <= '1';
          elsif DATA_RDATA = X"5D" then -- ]
              inc_cnt <= '1';
          end if;
			 nstate <= SWhileEnd5;
      
      when SWhileEnd5 =>
          if cnt_val = "0000000000000" then
              inc_pc <= '1';
              nstate <= SFetch;
          else
              dec_pc <= '1';
              nstate <= SWhileEnd3;  
			 end if;
          
      when SHalt =>
            nstate <= SHalt;
      
      when SOther =>  --unknown instructs are ignored 
            inc_pc <= '1';
            nstate <= SFetch;       
           
      when others =>  null;
   end case;
end process;

end behavioral;
 
