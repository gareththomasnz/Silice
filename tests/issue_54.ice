
algorithm bar(input uint8 i, output uint8 o)
{
  o = i;
}

algorithm main(input uint2 v)
{
  uint8 a = 8b10101010;
  uint8 b = 2;

  bar br;
  
  while (1) {
  
    a[2,2] = v;
    // a = v;
    (b) <- br <- (a);
    
  }
}
