import {
  IsNotEmpty,
  IsString,
  IsUUID,
} from 'class-validator';

export class CreateAccountDto {
  @IsUUID()
  customerId: string;

  @IsUUID()
  productId: string;

  @IsUUID()
  branchId: string;

  @IsString()
  @IsNotEmpty()
  currency: string;
}
