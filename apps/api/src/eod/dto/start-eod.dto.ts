import { IsNotEmpty, IsUUID } from 'class-validator';

export class StartEodDto {
  @IsUUID()
  @IsNotEmpty()
  businessDateId: string;
}
