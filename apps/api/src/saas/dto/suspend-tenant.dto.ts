import { IsNotEmpty, IsString } from 'class-validator';

export class SuspendTenantDto {
  @IsString()
  @IsNotEmpty()
  reason: string;
}
